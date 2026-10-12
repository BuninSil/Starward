extends MultiMeshInstance3D
## Smoke, dust and sparks: a small CPU particle system drawn as camera-facing
## soft billboards in one MultiMesh. Positions are kept in doubles relative to
## the centre of a body (inertial axes), so they stay put on the ground / in
## the air while the floating origin follows the vessel.

const MAX := 520

class P:
	var body: CelestialBody
	var pos: DVec3        ## relative to the body centre, inertial axes
	var vel: DVec3
	var age := 0.0
	var life := 1.0
	var size0 := 1.0
	var size1 := 3.0
	var color := Color.WHITE
	var glow := 0.0       ## emissive at birth (sparks, re-entry smoke)
	var drag := 0.0       ## 1/s: relaxes toward the air (body rotation) velocity
	var gravity := false
	var lift := 0.0       ## ground cloud: raised by this fraction of its size

var _ps: Array[P] = []
var _mm: MultiMesh


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
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var m := ShaderMaterial.new()
	m.shader = _shader()
	material_override = m
	# Bounds are wherever the particles are: never cull the whole batch.
	custom_aabb = AABB(Vector3(-1e5, -1e5, -1e5), Vector3(2e5, 2e5, 2e5))


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
	p.pos = pos
	p.vel = vel
	p.life = life
	p.size0 = size0
	p.size1 = size1
	p.color = color
	p.drag = drag
	p.gravity = gravity
	p.glow = glow
	p.lift = lift
	_ps.append(p)


## dt: simulated seconds (time warp included). origin: absolute position drawn
## at the scene origin; t: simulation time.
func step(dt: float, origin: DVec3, t: float) -> void:
	var cam := get_viewport().get_camera_3d()
	var i := 0
	var cache := {}
	while i < _ps.size():
		var p := _ps[i]
		p.age += dt
		if p.age >= p.life:
			_ps.remove_at(i)
			continue
		if p.drag > 0.0:
			var omega := DVec3.new(0, p.body.angular_velocity(), 0)
			var air := omega.cross(p.pos)
			var k := minf(p.drag * dt, 1.0)
			p.vel = p.vel.add(air.sub(p.vel).mul(k))
		if p.gravity:
			var r2 := p.pos.length_squared()
			p.vel.add_scaled(p.pos, -p.body.mu / (r2 * sqrt(r2)) * dt)
		p.pos.add_scaled(p.vel, dt)
		i += 1
	_mm.visible_instance_count = _ps.size()
	if _ps.is_empty() or cam == null:
		return
	var cb := cam.global_transform.basis
	for k in _ps.size():
		var p := _ps[k]
		var centre: DVec3 = cache.get(p.body, null)
		if centre == null:
			centre = p.body.absolute_position(t).sub(origin)
			cache[p.body] = centre
		var x := p.age / p.life
		var size := lerpf(p.size0, p.size1, 1.0 - pow(1.0 - x, 2.0))
		var at := centre.add(p.pos).to_v3()
		if p.lift > 0.0:
			# Keep the growing puff standing on the ground instead of sinking in.
			at += p.pos.normalized().to_v3() * size * p.lift
		_mm.set_instance_transform(k, Transform3D(cb.scaled(Vector3(size, size, size)), at))
		var a := p.color.a * smoothstep(0.0, 0.08, x) * (1.0 - smoothstep(0.55, 1.0, x))
		_mm.set_instance_color(k, Color(p.color.r, p.color.g, p.color.b, a))
		_mm.set_instance_custom_data(k, Color(p.glow * maxf(1.0 - x * 2.5, 0.0), float(k % 7) / 7.0, 1.0 if p.lift > 0.0 else 0.0, 0))


static var _sh: Shader


static func _shader() -> Shader:
	if _sh == null:
		_sh = Shader.new()
		_sh.code = """shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, shadows_disabled, unshaded;
uniform float light = 1.0;
uniform vec3 flame_pos = vec3(0.0);   // view... world position of the engine flame
uniform float flame_power = 0.0;      // 0..1
uniform float flame_reach = 40.0;
uniform vec3 lamp_pos = vec3(0.0);     // ship floodlights (night)
uniform float lamp_power = 0.0;
varying vec3 v_world;
varying vec4 v_col;
varying vec4 v_cus;
void vertex() {
	v_col = COLOR;
	v_cus = INSTANCE_CUSTOM;
	v_world = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
}
float h21(vec2 p) { return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453); }
float vnoise(vec2 p) {
	vec2 i = floor(p); vec2 f = fract(p); f = f * f * (3.0 - 2.0 * f);
	return mix(mix(h21(i), h21(i + vec2(1, 0)), f.x), mix(h21(i + vec2(0, 1)), h21(i + vec2(1, 1)), f.x), f.y);
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
	// Ground clouds: the lower edge thins out instead of a hard cut.
	a *= mix(1.0, smoothstep(0.42, 0.12, p.y), v_cus.z);
	ALPHA = a;
}
"""
	return _sh
