extends RigidBody3D
## Astronaut in EVA. Lives in the ship-centred local frame (ship origin = scene
## origin, inertial axes). Shared orbital gravity cancels out; what remains is
## relative motion, jetpack thrust and the pseudo-force from ship acceleration.

const MASS := 120.0                ## suit + astronaut, kg (without propellant)
const PROPELLANT_MAX := 5.0        ## kg of cold gas
const THRUST := 40.0               ## N per translation axis
const TORQUE := 18.0               ## N·m per rotation axis
const ISP := 70.0                  ## s, cold gas
const ROT_FUEL_ARM := 0.5          ## m, torque -> equivalent thrust for fuel use
const OXYGEN_MAX := 1200.0         ## seconds of oxygen (20 min)

var propellant := PROPELLANT_MAX
var oxygen := OXYGEN_MAX

## Inputs, set by the HUD each frame (-1..1). Local frame: x right, y up, z back.
var move_input := Vector3.ZERO      ## x strafe, y up/down, z forward(-)/back(+)
var rot_input := Vector3.ZERO       ## x pitch, y yaw, z roll
var stabilize := false              ## kill rotation
var kill_rel_velocity := false      ## null velocity relative to the ship
var face_target := false            ## turn to face `face_point`
var face_point := Vector3.ZERO
var ship_velocity := Vector3.ZERO   ## velocity of the ship frame point (always ~0 here)

var last_thrust := Vector3.ZERO     ## world-space thrust this tick, for effects
var _puffs: Array[MeshInstance3D] = []


func _ready() -> void:
	mass = MASS + propellant
	gravity_scale = 0.0
	linear_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	angular_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	linear_damp = 0.0
	angular_damp = 0.0
	can_sleep = false
	continuous_cd = true
	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.38
	cap.height = 1.85
	cs.shape = cap
	add_child(cs)
	_build_model()


func _build_model() -> void:
	var white := StandardMaterial3D.new()
	white.albedo_color = Color(0.93, 0.93, 0.92)
	white.roughness = 0.8
	var body := MeshInstance3D.new()
	var bm := CapsuleMesh.new()
	bm.radius = 0.32
	bm.height = 1.3
	body.mesh = bm
	body.material_override = white
	body.position.y = -0.15
	add_child(body)
	var helmet := MeshInstance3D.new()
	var hm := SphereMesh.new()
	hm.radius = 0.24
	hm.height = 0.48
	helmet.mesh = hm
	helmet.material_override = white
	helmet.position.y = 0.68
	add_child(helmet)
	var visor := MeshInstance3D.new()
	var vm := SphereMesh.new()
	vm.radius = 0.18
	vm.height = 0.3
	visor.mesh = vm
	var gold := StandardMaterial3D.new()
	gold.albedo_color = Color(0.95, 0.7, 0.25)
	gold.metallic = 1.0
	gold.roughness = 0.15
	visor.material_override = gold
	visor.position = Vector3(0, 0.7, -0.12)
	add_child(visor)
	var pack := MeshInstance3D.new()
	var pm := BoxMesh.new()
	pm.size = Vector3(0.55, 0.75, 0.3)
	pack.mesh = pm
	var grey := StandardMaterial3D.new()
	grey.albedo_color = Color(0.55, 0.57, 0.6)
	pack.material_override = grey
	pack.position = Vector3(0, 0.15, 0.32)
	add_child(pack)
	for limb in [Vector3(-0.42, 0.05, 0), Vector3(0.42, 0.05, 0), Vector3(-0.15, -0.95, 0), Vector3(0.15, -0.95, 0)]:
		var m := MeshInstance3D.new()
		var lm := CapsuleMesh.new()
		lm.radius = 0.1
		lm.height = 0.7
		m.mesh = lm
		m.material_override = white
		m.position = limb
		add_child(m)
	# Thruster puffs (visible while firing).
	var puff_mat := StandardMaterial3D.new()
	puff_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	puff_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	puff_mat.albedo_color = Color(0.9, 0.95, 1.0, 0.5)
	for dir in [Vector3.RIGHT, Vector3.LEFT, Vector3.UP, Vector3.DOWN, Vector3.FORWARD, Vector3.BACK]:
		var p := MeshInstance3D.new()
		var sm := SphereMesh.new()
		sm.radius = 0.08
		sm.height = 0.16
		p.mesh = sm
		p.material_override = puff_mat
		p.position = Vector3(0, 0.15, 0.32) + dir * 0.45
		p.visible = false
		p.set_meta("dir", dir)
		add_child(p)
		_puffs.append(p)


func has_propellant() -> bool:
	return propellant > 0.0


## ship_accel: non-gravitational acceleration of the ship (thrust, drag), world.
func physics_tick(dt: float, ship_accel: Vector3) -> void:
	oxygen = maxf(oxygen - dt, 0.0)
	var b := global_transform.basis
	# Pseudo-force: the ship frame accelerates, so the astronaut "falls" backwards.
	apply_central_force(-ship_accel * mass)

	var force_local := Vector3.ZERO
	var torque_local := Vector3.ZERO
	if has_propellant():
		force_local = move_input.limit_length(1.0) * THRUST
		torque_local = rot_input.limit_length(1.0) * TORQUE
		var w_local := b.inverse() * angular_velocity
		if stabilize or (rot_input.length() < 0.05 and face_target):
			var damp := -w_local * 30.0
			torque_local = (torque_local + damp).limit_length(TORQUE)
		if face_target:
			var to := (b.inverse() * (face_point - global_position)).normalized()
			# Face = local -Z toward the point: steer -Z onto `to`.
			var axis := Vector3.FORWARD.cross(to)
			var ang := Vector3.FORWARD.angle_to(to)
			if axis.length() > 1e-4:
				torque_local += (axis.normalized() * ang * 25.0 - w_local * 18.0)
				torque_local = torque_local.limit_length(TORQUE)
		if kill_rel_velocity:
			var rel := linear_velocity - ship_velocity
			var want := -(b.inverse() * rel) * mass / maxf(dt, 1e-3)
			force_local = (force_local + want).limit_length(THRUST * 1.7)
	var force_world := b * force_local
	apply_central_force(force_world)
	apply_torque(b * torque_local)
	last_thrust = force_world
	# Cold gas use: |F| dt / (Isp g0), torque via an equivalent arm.
	var used := (force_local.length() + torque_local.length() / ROT_FUEL_ARM) * dt / (ISP * 9.80665)
	propellant = maxf(propellant - used, 0.0)
	mass = MASS + propellant
	for p in _puffs:
		var dir: Vector3 = p.get_meta("dir")
		# A nozzle pointing along `dir` fires when thrust pushes opposite to it.
		p.visible = force_local.dot(-dir) > THRUST * 0.2 or (torque_local.length() > TORQUE * 0.3 and (dir == Vector3.UP or dir == Vector3.DOWN))
