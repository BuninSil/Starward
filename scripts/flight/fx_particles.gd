extends MultiMeshInstance3D
## Smoke, dust and sparks: a small CPU particle system drawn as camera-facing
## soft billboards in one MultiMesh. Positions are kept in doubles relative to
## the centre of a body (inertial axes), so they stay put on the ground / in
## the air while the floating origin follows the vessel.

const MAX := 520

class P:
	var body: CelestialBody
	## Position / velocity relative to the body centre, inertial axes (doubles,
	## plain floats: no per-frame vector allocations).
	var px := 0.0
	var py := 0.0
	var pz := 0.0
	var vx := 0.0
	var vy := 0.0
	var vz := 0.0
	var age := 0.0
	var life := 1.0
	var size0 := 1.0
	var size1 := 3.0
	var color := Color.WHITE
	var glow := 0.0       ## emissive at birth (sparks, re-entry smoke)
	var drag := 0.0       ## 1/s: relaxes toward the air (body rotation) velocity
	var gravity := false
	var lift := 0.0       ## ground cloud: raised by this fraction of its size
	var tone := 0.0       ## per-puff shape / tone variation

var _ps: Array[P] = []
var _mm: MultiMesh
var _buf := PackedFloat32Array()   ## 20 floats per instance: 3x4 transform, colour, custom
var _seed := 0


func _ready() -> void:
	_mm = MultiMesh.new()
	_mm.transform_format = MultiMesh.TRANSFORM_3D
	_mm.use_colors = true
	_mm.use_custom_data = true
	var q := QuadMesh.new()
	q.size = Vector2(1, 1)
	_mm.mesh = q
	_mm.instance_count = MAX
	_mm.visible_instance_count = 0
	multimesh = _mm
	_buf.resize(MAX * 20)
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var m := ShaderMaterial.new()
	m.shader = _shader()
	m.set_shader_parameter("lattice", _lattice())
	material_override = m
	# Bounds are wherever the particles are: never cull the whole batch.
	custom_aabb = AABB(Vector3(-1e5, -1e5, -1e5), Vector3(2e5, 2e5, 2e5))


## Local ground plane (scene coordinates) for soft ground contact; off when far.
func set_ground(p: Vector3, n: Vector3, on: bool) -> void:
	var m := material_override as ShaderMaterial
	m.set_shader_parameter("ground_p", p)
	m.set_shader_parameter("ground_n", n)
	m.set_shader_parameter("ground_on", 1.0 if on else 0.0)


## Engine flame lighting the smoke (scene position, 0..1, metres of reach).
func set_flame(pos: Vector3, power: float, reach: float) -> void:
	var m := material_override as ShaderMaterial
	m.set_shader_parameter("flame_pos", pos)
	m.set_shader_parameter("flame_power", power)
	m.set_shader_parameter("flame_reach", reach)


## The ship's floodlights at night light up nearby dust.
func set_lamp(pos: Vector3, power: float) -> void:
	var m := material_override as ShaderMaterial
	m.set_shader_parameter("lamp_pos", pos)
	m.set_shader_parameter("lamp_power", power)


## 0..1 overall light on the scene (night, shadow of the planet).
func set_light(l: float) -> void:
	(material_override as ShaderMaterial).set_shader_parameter("light", l)


func clear() -> void:
	_ps.clear()
	_mm.visible_instance_count = 0


func count() -> int:
	return _ps.size()


func emit(body: CelestialBody, pos: DVec3, vel: DVec3, life: float, size0: float, size1: float,
		color: Color, drag := 0.0, gravity := false, glow := 0.0, lift := 0.0) -> void:
	if _ps.size() >= MAX:
		_ps.pop_front()
	var p := P.new()
	p.body = body
	p.px = pos.x
	p.py = pos.y
	p.pz = pos.z
	p.vx = vel.x
	p.vy = vel.y
	p.vz = vel.z
	p.life = life
	p.size0 = size0
	p.size1 = size1
	p.color = color
	p.drag = drag
	p.gravity = gravity
	p.glow = glow
	p.lift = lift
	_seed = (_seed + 1) % 7
	p.tone = float(_seed) / 7.0
	_ps.append(p)


## dt: simulated seconds (time warp included). origin: absolute position drawn
## at the scene origin; t: simulation time.
func step(dt: float, origin: DVec3, t: float) -> void:
	# Dead particles out in one pass (order kept: draw order stays stable).
	var alive: Array[P] = []
	var dead := false
	for p in _ps:
		p.age += dt
		if p.age >= p.life:
			dead = true
	if dead:
		for p in _ps:
			if p.age < p.life:
				alive.append(p)
		_ps = alive
	var n := _ps.size()
	_mm.visible_instance_count = n
	var cam := get_viewport().get_camera_3d()
	if n == 0 or cam == null:
		return
	# Per body: spin rate, mu and its centre in scene coordinates (doubles).
	var bodies := {}
	for p in _ps:
		if not bodies.has(p.body):
			var c := p.body.absolute_position(t)
			bodies[p.body] = [p.body.angular_velocity(), p.body.mu, c.x - origin.x, c.y - origin.y, c.z - origin.z]
	var cb := cam.global_transform.basis
	var bx := cb.x
	var by := cb.y
	var bz := cb.z
	var buf := _buf
	var o := 0
	for k in n:
		var p := _ps[k]
		var bd: Array = bodies[p.body]
		if p.drag > 0.0:
			# Relax toward the air turning with the body: omega (0, w, 0) x pos.
			var w: float = bd[0]
			var kk := minf(p.drag * dt, 1.0)
			p.vx += (w * p.pz - p.vx) * kk
			p.vy += (0.0 - p.vy) * kk
			p.vz += (-w * p.px - p.vz) * kk
		if p.gravity:
			var r2 := p.px * p.px + p.py * p.py + p.pz * p.pz
			var g: float = -float(bd[1]) / (r2 * sqrt(r2)) * dt
			p.vx += p.px * g
			p.vy += p.py * g
			p.vz += p.pz * g
		p.px += p.vx * dt
		p.py += p.vy * dt
		p.pz += p.vz * dt
		var x := p.age / p.life
		var size := lerpf(p.size0, p.size1, 1.0 - (1.0 - x) * (1.0 - x))
		var ax: float = float(bd[2]) + p.px
		var ay: float = float(bd[3]) + p.py
		var az: float = float(bd[4]) + p.pz
		if p.lift > 0.0:
			# Keep the growing puff standing on the ground instead of sinking in.
			var lr := size * p.lift / sqrt(p.px * p.px + p.py * p.py + p.pz * p.pz)
			ax += p.px * lr
			ay += p.py * lr
			az += p.pz * lr
		# Row-major 3x4: camera basis scaled by size, then the origin.
		buf[o] = bx.x * size
		buf[o + 1] = by.x * size
		buf[o + 2] = bz.x * size
		buf[o + 3] = ax
		buf[o + 4] = bx.y * size
		buf[o + 5] = by.y * size
		buf[o + 6] = bz.y * size
		buf[o + 7] = ay
		buf[o + 8] = bx.z * size
		buf[o + 9] = by.z * size
		buf[o + 10] = bz.z * size
		buf[o + 11] = az
		var c := p.color
		buf[o + 12] = c.r
		buf[o + 13] = c.g
		buf[o + 14] = c.b
		buf[o + 15] = c.a * smoothstep(0.0, 0.08, x) * (1.0 - smoothstep(0.55, 1.0, x))
		buf[o + 16] = p.glow * maxf(1.0 - x * 2.5, 0.0)
		buf[o + 17] = p.tone
		buf[o + 18] = 1.0 if p.lift > 0.0 else 0.0
		buf[o + 19] = 0.0
		o += 20
	_buf = buf
	RenderingServer.multimesh_set_buffer(_mm.get_rid(), _buf)


static var _sh: Shader
static var _lat: ImageTexture


## Random values on a 64x64 integer lattice (wrapping). Read with one bilinear
## tap at floor(p) + smoothstep(fract(p)), this is the same value noise as
## hashing four corners, for the price of one texture read.
static func _lattice() -> ImageTexture:
	if _lat == null:
		var img := Image.create(64, 64, false, Image.FORMAT_RF)
		var rng := RandomNumberGenerator.new()
		rng.seed = 7
		for y in 64:
			for x in 64:
				img.set_pixel(x, y, Color(rng.randf(), 0, 0))
		_lat = ImageTexture.create_from_image(img)
	return _lat


static func _shader() -> Shader:
	if _sh == null:
		_sh = Shader.new()
		_sh.code = """shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, shadows_disabled, unshaded;
uniform float light = 1.0;
uniform vec3 ground_p = vec3(0.0);   // ground plane under the ship (scene)
uniform vec3 ground_n = vec3(0.0, 1.0, 0.0);
uniform float ground_on = 0.0;
uniform vec3 flame_pos = vec3(0.0);   // view... world position of the engine flame
uniform float flame_power = 0.0;      // 0..1
uniform float flame_reach = 40.0;
uniform vec3 lamp_pos = vec3(0.0);     // ship floodlights (night)
uniform float lamp_power = 0.0;
uniform sampler2D lattice : filter_linear, repeat_enable;
varying vec3 v_world;
varying vec4 v_col;
varying vec4 v_cus;
void vertex() {
	v_col = COLOR;
	v_cus = INSTANCE_CUSTOM;
	v_world = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
}
float vnoise(vec2 p) {
	vec2 i = floor(p); vec2 f = fract(p); f = f * f * (3.0 - 2.0 * f);
	return texture(lattice, (i + f + 0.5) / 64.0).r;
}
void fragment() {
	vec2 p = UV - 0.5;
	float r = length(p) * 2.0;
	// Puffy edge: a little noise per particle (seed in custom.y).
	float n = vnoise(p * 5.0 + v_cus.y * 17.0) * 0.35 + vnoise(p * 11.0 - v_cus.y * 9.0) * 0.15;
	// Cauliflower puff: lumpy edge, a rounded "volume" lit from above and
	// darker underneath, every puff a little different in tone.
	float lump = vnoise(p * 4.0 + v_cus.y * 23.0) * 0.5 + vnoise(p * 9.0 + v_cus.y * 5.0) * 0.3;
	float a = (1.0 - smoothstep(0.55, 0.8, r + lump * 0.5 - 0.2)) * v_col.a;
	float bulge = sqrt(max(1.0 - r * r, 0.0));
	float top = clamp(0.5 - p.y * 1.2 + (lump - 0.4) * 0.6, 0.0, 1.0);
	float shade = mix(0.42, 1.15, top * 0.65 + bulge * 0.35) * mix(0.82, 1.06, fract(v_cus.y * 7.31));
	// Unshaded (a lit billboard goes black against the sun); brightness follows
	// the scene light, glowing bits add on top.
	// The engine flame lights the clouds orange from below / inside.
	float fl = flame_power * exp(-length(v_world - flame_pos) / flame_reach) * (0.6 + 0.8 * (1.0 - top));
	float lp = lamp_power * exp(-length(v_world - lamp_pos) / 28.0);
	ALBEDO = v_col.rgb * (light * shade * (1.0 - 0.35 * fl) + vec3(1.0, 0.88, 0.72) * lp * 1.4 * shade)
		+ vec3(1.0, 0.5, 0.16) * (fl * 1.8 + v_cus.x * 1.5);
	// Soft contact with the ground (no depth texture on the mobile renderer):
	// the puff fades out over the last metres above the local ground plane.
	if (ground_on > 0.5) {
		vec3 wp = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
		a *= smoothstep(0.0, 3.0, dot(wp - ground_p, ground_n));
	}
	ALPHA = a;
}
"""
	return _sh
