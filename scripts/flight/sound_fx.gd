extends Node
## Flight sounds. The engine is real: NASA pad-microphone recordings of the
## Artemis II liftoff (public domain, assets/sounds/, made by
## .github/workflows/fetch-launch-audio.yml + tools/cut_launch_audio.py): roar in
## air, its deep part felt through the structure in vacuum, ignition from the
## pad, and the buffeting roar of the air at high dynamic pressure. The rest is
## synthesised in code at start-up (worker thread): wind, RCS puffs, staging
## bang, crash, hatch hiss and clunk, footsteps, suit breathing, jetpack puffs.
## Without the files the synthesised engine is used.
## flight.gd calls update() every frame and event() for one-shots.

const RATE := 22050

var _sounds := {}               ## name -> AudioStreamWAV
var _loops := {}                ## name -> AudioStreamPlayer
var _task := -1
var _ready_sounds := false
var _rcs_timer := 0.0
var _step_timer := 0.0
var _jet_timer := 0.0
var _pending: Array[String] = []
var _rng := RandomNumberGenerator.new()
var _was_off := 99.0      ## seconds the engine has been off
var _ign_time := 99.0     ## seconds since the ignition sound started
const SAMPLES := {"roar": "engine_air", "rumble": "engine_vac", "buffet": "buffet", "ignition": "ignition"}


## Recorded sound from assets/sounds/ (null when missing).
static func _sample(n: String, loop: bool) -> AudioStream:
	var path := "res://assets/sounds/%s.ogg" % n
	if not ResourceLoader.exists(path):
		return null
	var st := load(path) as AudioStreamOggVorbis
	if st != null:
		st = st.duplicate()
		st.loop = loop
	return st


func _ready() -> void:
	_task = WorkerThreadPool.add_task(_generate, false, "sound synthesis")


func _exit_tree() -> void:
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1


func _process(_delta: float) -> void:
	if _task >= 0 and WorkerThreadPool.is_task_completed(_task):
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
		for k in SAMPLES:
			var rec := _sample(SAMPLES[k], k != "ignition")
			if rec != null:
				_sounds[k] = rec
		for n in ["roar", "rumble", "wind", "breath", "buffet"]:
			if not _sounds.has(n):
				continue
			var p := AudioStreamPlayer.new()
			p.stream = _sounds[n]
			p.volume_db = -80.0
			add_child(p)
			p.play()
			_loops[n] = p
		_ready_sounds = true
		for e in _pending:
			event(e)
		_pending.clear()


## One-shot: "staging", "crash", "hatch_open", "hatch_close", "rcs", "step",
## "jet", "touchdown".
func event(name: String, volume_db := 0.0, pitch := 1.0) -> void:
	if not _ready_sounds:
		if name in ["hatch_open", "hatch_close", "staging"]:
			_pending.append(name)
		return
	var key := name
	match name:
		"hatch_open":
			_one("clunk", volume_db, 0.9)
			_one("hiss", volume_db - 4.0, 1.0)
			return
		"hatch_close":
			_one("clunk", volume_db, 1.05)
			return
		"touchdown":
			key = "thud"
		"jet":
			key = "rcs"
	if _sounds.has(key):
		_one(key, volume_db, pitch)


func _one(key: String, volume_db: float, pitch: float, vary := true) -> void:
	var p := AudioStreamPlayer.new()
	p.stream = _sounds[key]
	p.volume_db = volume_db
	p.pitch_scale = pitch * (_rng.randf_range(0.94, 1.06) if vary else 1.0)
	add_child(p)
	p.play()
	p.finished.connect(p.queue_free)


## Continuous sounds. thrust 0..1; pressure 0..1 (sea level = 1); q = dynamic
## pressure in Pa; rcs = attitude thrusters firing; eva = astronaut outside,
## walking speed, jetpack firing; listener outside = EVA (engine heard muffled).
func update(delta: float, thrust: float, pressure: float, q: float, rcs: bool,
		eva: bool, walk_speed: float, on_ground: bool, jet: bool) -> void:
	if not _ready_sounds:
		return
	var thr := clampf(thrust, 0.0, 1.0)
	var on := thr > 0.001
	var air := clampf(pressure * 3.0, 0.0, 1.0)
	var muffle := 0.35 if eva else 1.0
	var recorded := _sounds.roar is AudioStreamOggVorbis
	# Ignition from the pad (engine off for a while, thick air): the recording
	# of the real start-up plays and the steady roar fades in under its end.
	_ign_time += delta
	if on and _was_off > 2.0 and air > 0.6 and not eva and _sounds.has("ignition"):
		_one("ignition", 0.0, 1.0, false)
		_ign_time = 0.0
	_was_off = 0.0 if on else _was_off + delta
	var ign_fade := smoothstep(4.0, 9.0, _ign_time)
	# Recordings keep their pitch (shifting them sounds fake); the synthesised
	# roar follows the throttle.
	var roar_pitch := (0.96 + 0.06 * thr) if recorded else (0.85 + 0.3 * thr)
	_set_loop(_loops.roar, (0.25 + 0.75 * thr) * air * muffle * ign_fade if on else 0.0, roar_pitch)
	_set_loop(_loops.rumble, (0.3 + 0.6 * thr) * (1.0 - air * 0.6) * (0.3 if eva else 1.0) if on else 0.0,
		1.0 if recorded else 0.8 + 0.25 * thr)
	var w := clampf(q / 30000.0, 0.0, 1.0)
	_set_loop(_loops.wind, w * 0.9 * muffle, 0.7 + 0.6 * w)
	if _loops.has("buffet"):
		# Heavy roar of the air on the hull: from ~10 kPa (max-q, re-entry).
		_set_loop(_loops.buffet, smoothstep(0.25, 1.0, w) * 0.9 * muffle, 1.0)
	_set_loop(_loops.breath, 0.55 if eva else 0.0, 1.0)
	# RCS chatter while turning.
	_rcs_timer -= delta
	if rcs and not eva and _rcs_timer <= 0.0:
		_rcs_timer = _rng.randf_range(0.09, 0.16)
		event("rcs", -8.0)
	# Footsteps on the ground, jetpack puffs in space.
	_step_timer -= delta
	if eva and on_ground and walk_speed > 0.3 and _step_timer <= 0.0:
		_step_timer = clampf(0.9 / maxf(walk_speed, 0.5), 0.3, 0.7)
		event("step", -6.0)
	_jet_timer -= delta
	if eva and jet and _jet_timer <= 0.0:
		_jet_timer = 0.11
		event("jet", -10.0, 1.3)


func _set_loop(p: AudioStreamPlayer, amp: float, pitch: float) -> void:
	var target := linear_to_db(maxf(amp, 0.0001))
	# Smooth volume changes (avoids zipper noise).
	p.volume_db = lerpf(p.volume_db, target, 0.15)
	p.pitch_scale = lerpf(p.pitch_scale, maxf(pitch, 0.1), 0.15)


# --- Synthesis (worker thread: pure data) -----------------------------------------

func _generate() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 1234
	_sounds["roar"] = _loop(_roar(rng, 2.5))
	_sounds["rumble"] = _loop(_rumble(rng, 2.5))
	_sounds["wind"] = _loop(_wind(rng, 3.0))
	_sounds["breath"] = _loop(_breath(rng, 4.2))
	_sounds["rcs"] = _wav(_burst(rng, 0.14, 0.35, 0.0, 0.85))
	_sounds["hiss"] = _wav(_burst(rng, 0.9, 0.25, 0.0, 0.6))
	_sounds["clunk"] = _wav(_clunk(rng))
	_sounds["staging"] = _wav(_bang(rng, 0.9, 0.7))
	_sounds["crash"] = _wav(_bang(rng, 2.2, 1.0))
	_sounds["thud"] = _wav(_bang(rng, 0.5, 0.4))
	_sounds["step"] = _wav(_step(rng))


## 16-bit mono WAV from float samples in -1..1.
func _wav(s: PackedFloat32Array, loop := false) -> AudioStreamWAV:
	var data := PackedByteArray()
	data.resize(s.size() * 2)
	for i in s.size():
		data.encode_s16(i * 2, int(clampf(s[i], -1.0, 1.0) * 32000.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = RATE
	w.stereo = false
	w.data = data
	if loop:
		w.loop_mode = AudioStreamWAV.LOOP_FORWARD
		w.loop_begin = 0
		w.loop_end = s.size()
	return w


## Seamless loop: cross-fade the last 0.25 s into the start.
func _loop(s: PackedFloat32Array) -> AudioStreamWAV:
	var f := int(RATE * 0.25)
	var n := s.size() - f
	var out := PackedFloat32Array()
	out.resize(n)
	for i in n:
		out[i] = s[i]
	for i in f:
		var t := float(i) / f
		out[i] = s[n + i] * (1.0 - t) + s[i] * t
	return _wav(out, true)


## Rocket roar: low-passed noise layers plus crackle, slow pulsing.
func _roar(rng: RandomNumberGenerator, sec: float) -> PackedFloat32Array:
	var n := int(RATE * sec)
	var s := PackedFloat32Array()
	s.resize(n)
	var lp1 := 0.0
	var lp2 := 0.0
	var lp3 := 0.0
	for i in n:
		var w := rng.randf_range(-1.0, 1.0)
		lp1 += 0.35 * (w - lp1)
		lp2 += 0.06 * (w - lp2)
		lp3 += 0.012 * (w - lp3)
		var crackle := (rng.randf_range(-1.0, 1.0) if rng.randf() < 0.004 else 0.0) * 0.9
		var t := float(i) / RATE
		var pulse := 0.85 + 0.15 * sin(t * TAU * 7.3) * sin(t * TAU * 2.1)
		s[i] = (lp1 * 0.35 + lp2 * 1.4 + lp3 * 4.0 + crackle) * pulse * 0.6
	return s


## Engine heard through the structure in vacuum: deep rumble with a hum.
func _rumble(rng: RandomNumberGenerator, sec: float) -> PackedFloat32Array:
	var n := int(RATE * sec)
	var s := PackedFloat32Array()
	s.resize(n)
	var lp := 0.0
	var lp2 := 0.0
	for i in n:
		var w := rng.randf_range(-1.0, 1.0)
		lp += 0.02 * (w - lp)
		lp2 += 0.004 * (w - lp2)
		var t := float(i) / RATE
		s[i] = (lp * 3.5 + lp2 * 9.0) * 0.6 + sin(t * TAU * 48.0) * 0.08 + sin(t * TAU * 96.0) * 0.04
	return s


## Wind: band-limited noise with gusts.
func _wind(rng: RandomNumberGenerator, sec: float) -> PackedFloat32Array:
	var n := int(RATE * sec)
	var s := PackedFloat32Array()
	s.resize(n)
	var a := 0.0
	var b := 0.0
	for i in n:
		var w := rng.randf_range(-1.0, 1.0)
		a += 0.12 * (w - a)
		b += 0.03 * (a - b)
		var t := float(i) / RATE
		var gust := 0.7 + 0.3 * sin(t * TAU * 0.67) * sin(t * TAU * 1.3 + 1.0)
		s[i] = (a - b) * 2.2 * gust
	return s


## Suit breathing: inhale / exhale as filtered noise with envelopes.
func _breath(rng: RandomNumberGenerator, sec: float) -> PackedFloat32Array:
	var n := int(RATE * sec)
	var s := PackedFloat32Array()
	s.resize(n)
	var a := 0.0
	var b := 0.0
	for i in n:
		var t := float(i) / RATE
		var cyc := fmod(t, sec) / sec
		# Inhale 0..0.35, pause, exhale 0.45..0.85.
		var env := 0.0
		if cyc < 0.35:
			env = sin(cyc / 0.35 * PI) * 0.7
		elif cyc > 0.45 and cyc < 0.85:
			env = sin((cyc - 0.45) / 0.4 * PI)
		var w := rng.randf_range(-1.0, 1.0)
		a += (0.25 if cyc < 0.4 else 0.15) * (w - a)
		b += 0.02 * (a - b)
		s[i] = (a - b) * env * 0.95
	return s


## Gas burst (RCS, air hiss): noise with attack/decay; hp > 0 brightens.
func _burst(rng: RandomNumberGenerator, sec: float, decay: float, _hp: float, amp: float) -> PackedFloat32Array:
	var n := int(RATE * sec)
	var s := PackedFloat32Array()
	s.resize(n)
	var lp := 0.0
	for i in n:
		var t := float(i) / RATE
		var w := rng.randf_range(-1.0, 1.0)
		lp += 0.5 * (w - lp)
		var env := minf(t / 0.008, 1.0) * exp(-t / (sec * decay))
		s[i] = (w - lp * 0.6) * env * amp
	return s


## Mechanical clunk: low thump + metallic ring + click.
func _clunk(rng: RandomNumberGenerator) -> PackedFloat32Array:
	var n := int(RATE * 0.6)
	var s := PackedFloat32Array()
	s.resize(n)
	for i in n:
		var t := float(i) / RATE
		var thump := sin(t * TAU * 70.0) * exp(-t / 0.06)
		var ring := (sin(t * TAU * 640.0) * 0.4 + sin(t * TAU * 1130.0) * 0.25) * exp(-t / 0.12)
		var click := rng.randf_range(-1.0, 1.0) * exp(-t / 0.006)
		s[i] = (thump * 0.9 + ring * 0.5 + click * 0.6) * 0.6
	return s


## Explosive bang (pyro bolts, crash): sharp noise + low boom, long tail.
func _bang(rng: RandomNumberGenerator, sec: float, power: float) -> PackedFloat32Array:
	var n := int(RATE * sec)
	var s := PackedFloat32Array()
	s.resize(n)
	var lp := 0.0
	for i in n:
		var t := float(i) / RATE
		var w := rng.randf_range(-1.0, 1.0)
		lp += 0.05 * (w - lp)
		var crack := w * exp(-t / 0.02)
		var boom := (lp * 4.0 + sin(t * TAU * 45.0 * (1.0 - t * 0.3)) * 0.6) * exp(-t / (0.25 * sec))
		s[i] = (crack * 0.7 + boom) * power * 0.6
	return s


## Footstep: muffled thud + gravel crunch.
func _step(rng: RandomNumberGenerator) -> PackedFloat32Array:
	var n := int(RATE * 0.22)
	var s := PackedFloat32Array()
	s.resize(n)
	var lp := 0.0
	for i in n:
		var t := float(i) / RATE
		var w := rng.randf_range(-1.0, 1.0)
		lp += 0.08 * (w - lp)
		var thud := lp * 3.0 * exp(-t / 0.03)
		var crunch := w * float(rng.randf() < 0.3) * exp(-t / 0.06) * 0.5
		s[i] = (thud + crunch) * 0.7
	return s
