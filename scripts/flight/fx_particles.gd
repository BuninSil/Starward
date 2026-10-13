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
	_mm.mesh = _octagon()
	_mm.instance_count = MAX
	_mm.visible_instance_count = 0
	multimesh = _mm
	_buf.resize(MAX * 20)
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var m := ShaderMaterial.new()
	m.shader = _shader()
	m.set_shader_parameter("atlas", _atlas())
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
static var _atl: ImageTexture
const TILE := 96        ## atlas tile size (px); 7 puff variants side by side
const VARIANTS := 7


## The puff shapes, computed once: for each of the 7 variants the lumpy edge
## mask (R), the "lit from above" term (G) and the volume shading (B), exactly
## what the shader used to work out per pixel from value noise. The fragment
## shader now reads one texel instead of four noise lookups and the maths.
static var _atl_task := -1
static var _atl_mutex := Mutex.new()


## Starts building the atlas in the background (called at game start).
static func prepare() -> void:
	if _atl == null and _atl_task < 0:
		_atl_task = WorkerThreadPool.add_task(_atlas)


static func _atlas() -> ImageTexture:
	if _atl_task >= 0 and not WorkerThreadPool.is_task_completed(_atl_task) \
			and OS.get_thread_caller_id() == OS.get_main_thread_id():
		WorkerThreadPool.wait_for_task_completion(_atl_task)
		_atl_task = -1
	_atl_mutex.lock()
	if _atl != null:
		_atl_mutex.unlock()
		return _atl
	var lat := PackedFloat32Array()
	lat.resize(64 * 64)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for i in 64 * 64:
		lat[i] = rng.randf()
	var vnoise := func(x: float, y: float) -> float:
		var ix := floori(x)
		var iy := floori(y)
		var fx := x - ix
		var fy := y - iy
		fx = fx * fx * (3.0 - 2.0 * fx)
		fy = fy * fy * (3.0 - 2.0 * fy)
		var x0 := posmod(ix, 64)
		var y0 := posmod(iy, 64)
		var x1 := (x0 + 1) % 64
		var y1 := (y0 + 1) % 64
		var a := lerpf(lat[y0 * 64 + x0], lat[y0 * 64 + x1], fx)
		var b := lerpf(lat[y1 * 64 + x0], lat[y1 * 64 + x1], fx)
		return lerpf(a, b, fy)
	var data := PackedByteArray()
	data.resize(TILE * VARIANTS * TILE * 4)
	for k in VARIANTS:
		var sd := float(k) / VARIANTS
		var tone := lerpf(0.82, 1.06, fposmod(sd * 7.31, 1.0))
		for y in TILE:
			for x in TILE:
				var px := (x + 0.5) / TILE - 0.5
				var py := (y + 0.5) / TILE - 0.5
				var r := sqrt(px * px + py * py) * 2.0
				var lump: float = vnoise.call(px * 4.0 + sd * 23.0, py * 4.0 + sd * 23.0) * 0.5 \
					+ vnoise.call(px * 9.0 + sd * 5.0, py * 9.0 + sd * 5.0) * 0.3
				var mask := 1.0 - smoothstep(0.55, 0.8, r + lump * 0.5 - 0.2)
				var bulge := sqrt(maxf(1.0 - r * r, 0.0))
				var top := clampf(0.5 - py * 1.2 + (lump - 0.4) * 0.6, 0.0, 1.0)
				var shade := lerpf(0.42, 1.15, top * 0.65 + bulge * 0.35) * tone
				var o := (y * TILE * VARIANTS + k * TILE + x) * 4
				data[o] = int(round(mask * 255.0))
				data[o + 1] = int(round(top * 255.0))
				data[o + 2] = int(round(clampf(shade / 1.25, 0.0, 1.0) * 255.0))
				data[o + 3] = 255
	var img := Image.create_from_data(TILE * VARIANTS, TILE, false, Image.FORMAT_RGBA8, data)
	img.generate_mipmaps()
	_atl = ImageTexture.create_from_image(img)
	_atl_mutex.unlock()
	return _atl


## Billboard octagon around the unit puff (the quad's corners are always
## transparent but still cost fill rate). UV as on a QuadMesh.
static func _octagon() -> ArrayMesh:
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var R := 0.5 / cos(PI / 8.0)
	var ring: Array[Vector3] = []
	for i in 8:
		var ang := PI / 8.0 + TAU * i / 8.0
		ring.append(Vector3(cos(ang) * R, sin(ang) * R, 0.0))
	for i in 8:
		for v in [Vector3.ZERO, ring[i], ring[(i + 1) % 8]]:
			verts.append(v)
			uvs.append(Vector2(v.x + 0.5, 0.5 - v.y))
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_TEX_UV] = uvs
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return m


static func _shader() -> Shader:
	if _sh == null:
		_sh = Shader.new()
		_sh.code = """shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, shadows_disabled, unshaded;
uniform float light = 1.0;
uniform vec3 ground_p = vec3(0.0);   // ground plane under the ship (scene)
uniform vec3 ground_n = vec3(0.0, 1.0, 0.0);
uniform float ground_on = 0.0;
uniform vec3 flame_pos = vec3(0.0);   // world position of the engine flame
uniform float flame_power = 0.0;      // 0..1
uniform float flame_reach = 40.0;
uniform vec3 lamp_pos = vec3(0.0);     // ship floodlights (night)
uniform float lamp_power = 0.0;
uniform sampler2D atlas : filter_linear_mipmap, repeat_disable;
varying vec4 v_col;
varying float v_glow;
varying float v_tile;
varying float v_fl;      // flame light reaching this puff
varying float v_lp;      // floodlight reaching this puff
varying float v_gh;      // height above the local ground plane
void vertex() {
	v_col = COLOR;
	v_glow = INSTANCE_CUSTOM.x;
	v_tile = floor(INSTANCE_CUSTOM.y * 7.0 + 0.5);
	vec3 centre = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	v_fl = flame_power * exp(-length(centre - flame_pos) / flame_reach);
	v_lp = lamp_power * exp(-length(centre - lamp_pos) / 28.0);
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_gh = dot(wp - ground_p, ground_n);
}
void fragment() {
	// Puff shape from the atlas: R edge mask, G lit-from-above, B volume shading.
	vec4 t = texture(atlas, vec2((v_tile + clamp(UV.x, 0.0, 1.0)) / 7.0, UV.y));
	float a = t.r * v_col.a;
	float top = t.g;
	float shade = t.b * 1.25;
	// Unshaded (a lit billboard goes black against the sun); brightness follows
	// the scene light, the engine flame lights the clouds orange from below.
	float fl = v_fl * (0.6 + 0.8 * (1.0 - top));
	ALBEDO = v_col.rgb * (light * shade * (1.0 - 0.35 * fl) + vec3(1.0, 0.88, 0.72) * v_lp * 1.4 * shade)
		+ vec3(1.0, 0.5, 0.16) * (fl * 1.8 + v_glow * 1.5);
	// Soft contact with the ground (no depth texture on the mobile renderer).
	if (ground_on > 0.5) {
		a *= smoothstep(0.0, 3.0, v_gh);
	}
	ALPHA = a;
}
"""
	return _sh
