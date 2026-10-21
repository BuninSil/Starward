extends MultiMeshInstance3D
## Supercruise look: streaks of light rushing past the camera, longer and
## brighter the faster the ship goes (on a log scale: 300 m/s .. 7 c). Pure
## visual, lives in render space around the camera.

const COUNT := 220
const BOX := 70.0       ## half-size of the box of streaks around the camera, m

var _pts: PackedVector3Array = []
var _fade := 0.0


func _ready() -> void:
	var mesh := QuadMesh.new()
	mesh.size = Vector2(1, 1)
	var mat := ShaderMaterial.new()
	mat.shader = Shader.new()
	mat.shader.code = """
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled;
uniform float bright = 1.0;
void fragment() {
	// Thin bright core, soft edges, fading head and tail.
	float w = 1.0 - abs(UV.x * 2.0 - 1.0);
	float l = sin(UV.y * 3.14159);
	float a = w * w * l * bright * COLOR.a;
	ALBEDO = vec3(0.75, 0.85, 1.0) * a;
}
"""
	mesh.material = mat
	multimesh = MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.use_colors = true
	multimesh.instance_count = COUNT
	multimesh.mesh = mesh
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	extra_cull_margin = 16384.0
	_pts.resize(COUNT)
	for i in COUNT:
		_pts[i] = Vector3(randf_range(-BOX, BOX), randf_range(-BOX, BOX), randf_range(-BOX, BOX))
	visible = false


## dir: world direction of flight, speed: cruise speed (0 = off), cam: camera.
func update_fx(delta: float, dir: Vector3, speed: float, cam: Camera3D) -> void:
	_fade = move_toward(_fade, 1.0 if speed > 0.0 else 0.0, delta * 1.5)
	visible = _fade > 0.0
	if not visible:
		return
	# Apparent speed of the streaks: grows with the log of the real one.
	var k := clampf(log(maxf(speed, 300.0) / 300.0) / log(1.0e7), 0.0, 1.0)
	var vis := lerpf(25.0, 260.0, k)
	var length := lerpf(1.0, 30.0, k)
	var width := lerpf(0.07, 0.16, k)
	var c := cam.global_position
	global_position = Vector3.ZERO
	var view := cam.global_transform.basis.z
	for i in COUNT:
		var p := _pts[i] - dir * vis * delta
		# Wrap around the box (streaks re-enter ahead of the ship).
		for a in 3:
			if p[a] < -BOX:
				p[a] += BOX * 2.0
			elif p[a] > BOX:
				p[a] -= BOX * 2.0
		_pts[i] = p
		var y := dir * length
		var x := dir.cross(view)
		x = (x.normalized() if x.length() > 1e-3 else cam.global_transform.basis.x) * width
		var z := x.cross(y).normalized()
		# Streaks close to the camera are faint (no flashes in the face).
		var dist := p.length()
		var a := _fade * smoothstep(4.0, 14.0, dist) * (1.0 - smoothstep(BOX * 0.7, BOX, dist))
		multimesh.set_instance_transform(i, Transform3D(Basis(x, y, z), c + p))
		multimesh.set_instance_color(i, Color(1, 1, 1, minf(a * lerpf(0.8, 1.6, k), 1.0)))
