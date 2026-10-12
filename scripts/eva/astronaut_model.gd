extends Node3D
## Visual astronaut: the CC0 Quaternius "Astronaut" (Ultimate Space Kit) with
## its animations, the cartoon head collapsed and replaced by our own helmet
## with a gold visor, a life-support backpack and a chest unit; the pistol of
## the original model is hidden. Feet at this node's origin, faces -Z,
## ~1.85 m tall. Physics stays in astronaut.gd; this only animates.

const MODEL := preload("res://assets/astronaut/astronaut.glb")
const HEIGHT := 1.85

var _anim: AnimationPlayer
var _skel: Skeleton3D
var _model: Node3D
var _helmet: Node3D
var _pack: Node3D
var _neck_att: BoneAttachment3D
var _torso_att: BoneAttachment3D
var _state := ""
var _scale := 1.0
## Thruster puff anchors (in this node's frame), around the backpack.
var pack_centre := Vector3(0, 1.25, 0.28)


func _ready() -> void:
	_model = MODEL.instantiate() as Node3D
	add_child(_model)
	_model.rotation.y = PI   # glTF faces +Z, our astronaut faces -Z
	_skel = _model.find_child("Skeleton3D", true, false) as Skeleton3D
	_anim = _model.find_child("AnimationPlayer", true, false) as AnimationPlayer
	for m in _model.find_children("*", "MeshInstance3D", true, false):
		if m.name == "Pistol":
			(m as Node3D).visible = false
	# Scale so the neck sits at ~1.55 m.
	var neck := _skel.find_bone("Neck")
	var neck_y := (_skel.global_transform * _skel.get_bone_global_rest(neck)).origin.y - global_position.y
	_scale = 1.55 / maxf(neck_y, 0.01)
	_model.scale = Vector3.ONE * _scale
	var hider := HeadHider.new()
	_skel.add_child(hider)
	for n in ["Idle", "Walk", "Run", "Jump_Idle"]:
		var a := _anim.get_animation("CharacterArmature|" + n)
		if a:
			a.loop_mode = Animation.LOOP_LINEAR
	_neck_att = _attach("Neck")
	_torso_att = _attach("Torso")
	_build_helmet()
	_build_pack()
	play("float")


func _attach(bone: String) -> BoneAttachment3D:
	var att := BoneAttachment3D.new()
	att.bone_name = bone
	_skel.add_child(att)
	return att


func _build_helmet() -> void:
	_helmet = Node3D.new()
	_helmet.top_level = true
	add_child(_helmet)
	var white := _mat(Color(0.95, 0.95, 0.94), 0.35, 0.0)
	var shell := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.23
	sm.height = 0.46
	shell.mesh = sm
	shell.material_override = white
	shell.position = Vector3(0, 0.15, 0.0)
	_helmet.add_child(shell)
	# Gold visor: a flattened sphere cap in front.
	var visor := MeshInstance3D.new()
	var vm := SphereMesh.new()
	vm.radius = 0.19
	vm.height = 0.31
	visor.mesh = vm
	visor.material_override = _mat(Color(0.95, 0.72, 0.28), 0.12, 1.0)
	visor.position = Vector3(0, 0.15, -0.115)
	visor.scale = Vector3(1.0, 0.92, 0.78)
	_helmet.add_child(visor)
	# Neck ring.
	var ring := MeshInstance3D.new()
	var rm := TorusMesh.new()
	rm.inner_radius = 0.13
	rm.outer_radius = 0.19
	ring.mesh = rm
	ring.material_override = _mat(Color(0.55, 0.57, 0.6), 0.4, 0.6)
	ring.position = Vector3(0, 0.0, 0)
	_helmet.add_child(ring)
	# Helmet lamps on the sides.
	for sx in [-1.0, 1.0]:
		var lamp := MeshInstance3D.new()
		var lm := CylinderMesh.new()
		lm.top_radius = 0.035
		lm.bottom_radius = 0.035
		lm.height = 0.08
		lamp.mesh = lm
		lamp.material_override = _mat(Color(0.3, 0.3, 0.32), 0.4, 0.5)
		lamp.rotation.z = PI * 0.5
		lamp.position = Vector3(sx * 0.23, 0.19, -0.02)
		_helmet.add_child(lamp)


func _build_pack() -> void:
	_pack = Node3D.new()
	_pack.top_level = true
	add_child(_pack)
	var white := _mat(Color(0.9, 0.9, 0.88), 0.5, 0.0)
	var pk := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.5, 0.62, 0.24)
	pk.mesh = bm
	pk.material_override = white
	pk.position = Vector3(0, 0.05, 0.27)
	_pack.add_child(pk)
	var top := MeshInstance3D.new()
	var tm := BoxMesh.new()
	tm.size = Vector3(0.46, 0.14, 0.2)
	top.mesh = tm
	top.material_override = _mat(Color(0.6, 0.62, 0.65), 0.4, 0.5)
	top.position = Vector3(0, 0.43, 0.27)
	_pack.add_child(top)
	# Thruster nozzles at the corners.
	for c in [Vector3(-0.25, 0.32, 0.38), Vector3(0.25, 0.32, 0.38), Vector3(-0.25, -0.22, 0.38), Vector3(0.25, -0.22, 0.38)]:
		var n := MeshInstance3D.new()
		var cm := CylinderMesh.new()
		cm.top_radius = 0.025
		cm.bottom_radius = 0.045
		cm.height = 0.08
		n.mesh = cm
		n.material_override = _mat(Color(0.25, 0.25, 0.27), 0.4, 0.6)
		n.position = c
		_pack.add_child(n)
	# Chest control box.
	var chest := MeshInstance3D.new()
	var chm := BoxMesh.new()
	chm.size = Vector3(0.28, 0.16, 0.1)
	chest.mesh = chm
	chest.material_override = _mat(Color(0.75, 0.76, 0.78), 0.45, 0.3)
	chest.position = Vector3(0, -0.02, -0.24)
	_pack.add_child(chest)


func _mat(c: Color, rough: float, metal: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = rough
	m.metallic = metal * 0.3   # no environment reflections on mobile
	m.metallic_specular = 0.5 + 0.4 * metal
	return m


## Animation state: "float" (EVA in space), "idle", "walk", "run", "jump".
func play(state: String, speed := 1.0) -> void:
	if state != _state:
		_state = state
		var n := "Idle"
		match state:
			"walk": n = "Walk"
			"run": n = "Run"
			"jump": n = "Jump_Idle"
		_anim.play("CharacterArmature|" + n, 0.25)
	_anim.speed_scale = 0.45 if state == "float" else speed


func _process(_delta: float) -> void:
	_follow(_helmet, _neck_att)
	_follow(_pack, _torso_att)


## Part placed at the bone (position follows the animation), facing the body.
func _follow(part: Node3D, att: BoneAttachment3D) -> void:
	if part == null:
		return
	part.global_transform = Transform3D(global_transform.basis.orthonormalized(), att.global_transform.origin)
