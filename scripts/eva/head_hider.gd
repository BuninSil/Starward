class_name HeadHider
extends SkeletonModifier3D
## Collapses one bone (and its skinned vertices) after the animation runs:
## used to hide the cartoon head of the CC0 astronaut model under our helmet.

@export var bone_name := "Head"
var _bone := -1


func _process_modification() -> void:
	var sk := get_skeleton()
	if sk == null:
		return
	if _bone < 0:
		_bone = sk.find_bone(bone_name)
		if _bone < 0:
			return
	sk.set_bone_pose_scale(_bone, Vector3(0.001, 0.001, 0.001))
