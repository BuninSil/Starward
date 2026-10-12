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

# Surface (walking) mode
var surface_mode := false
var up_dir := Vector3.UP            ## local vertical (away from the body centre)
var gravity := 0.0                  ## m/s^2 toward -up_dir
var breathable := false             ## Earth near the surface: no oxygen use
var walk_input := Vector2.ZERO      ## x right, y forward (relative to `cam_forward`)
var cam_forward := Vector3.FORWARD
var jump_requested := false
var on_ground := false
const WALK_SPEED := 4.0           ## m/s on Earth (brisk jog)
const WALK_SPEED_LOW_G := 3.2     ## m/s in low gravity (bounding gait)
const JUMP_SPEED := 2.2
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


const ModelScript := preload("res://scripts/eva/astronaut_model.gd")
var model: Node3D


func _build_model() -> void:
	# Animated suit (feet at the bottom of the collision capsule).
	model = ModelScript.new()
	model.position.y = -0.925
	add_child(model)
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
		p.position = Vector3(0, 0.35, 0.36) + dir * 0.4
		p.visible = false
		p.set_meta("dir", dir)
		add_child(p)
		_puffs.append(p)


func has_propellant() -> bool:
	return propellant > 0.0


## ship_accel: non-gravitational acceleration of the ship (thrust, drag), world.
func physics_tick(dt: float, ship_accel: Vector3) -> void:
	if not breathable:
		oxygen = maxf(oxygen - dt, 0.0)
	_update_animation()
	if surface_mode:
		_walk_tick(dt)
		return
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


## Picks the suit animation from the motion state.
func _update_animation() -> void:
	if model == null:
		return
	if not surface_mode:
		model.play("float")
		return
	var v_h := linear_velocity - up_dir * linear_velocity.dot(up_dir)
	var sp := v_h.length()
	if not on_ground:
		model.play("jump")
	elif sp > 2.6:
		model.play("run", clampf(sp / 4.0, 0.6, 1.4))
	elif sp > 0.25:
		model.play("walk", clampf(sp / 1.6, 0.5, 1.6))
	else:
		model.play("idle")


func set_surface_mode(on: bool, up: Vector3, g: float, air: bool) -> void:
	surface_mode = on
	up_dir = up
	gravity = g
	if model:
		model.low_gravity = g < 3.0
	breathable = air
	axis_lock_angular_x = on
	axis_lock_angular_y = on
	axis_lock_angular_z = on
	angular_velocity = Vector3.ZERO
	for p in _puffs:
		p.visible = false


func _walk_tick(dt: float) -> void:
	apply_central_force(-up_dir * gravity * mass)
	# Ground check: short ray down from the body centre.
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(global_position, global_position - up_dir * 1.05)
	q.exclude = [get_rid()]
	on_ground = not space.intersect_ray(q).is_empty()
	# Heading from the camera, projected on the horizon.
	var fwd := cam_forward - up_dir * cam_forward.dot(up_dir)
	fwd = fwd.normalized() if fwd.length() > 1e-3 else up_dir.cross(Vector3.RIGHT).normalized()
	var right := fwd.cross(up_dir)
	var move := (fwd * walk_input.y + right * walk_input.x).limit_length(1.0)
	var v_up := linear_velocity.dot(up_dir)
	var v_h := linear_velocity - up_dir * v_up
	if on_ground:
		# Snappy on the ground, but low gravity means slow stops (feels lunar).
		var target := move * (WALK_SPEED if gravity > 3.0 else WALK_SPEED_LOW_G)
		var accel := 14.0 if gravity > 3.0 else 7.0
		v_h = v_h.move_toward(target, accel * dt)
		if jump_requested:
			v_up = JUMP_SPEED if gravity < 3.0 else JUMP_SPEED * 1.3
		jump_requested = false
		linear_velocity = v_h + up_dir * v_up
	else:
		jump_requested = false
		# A little air control.
		linear_velocity += move * 1.0 * dt
	# Stand upright, face the walking direction (or the camera heading).
	var face := move if move.length() > 0.1 else (fwd if not on_ground else -global_transform.basis.z)
	face = face - up_dir * face.dot(up_dir)
	if face.length() > 1e-3:
		var z := -face.normalized()
		var x := up_dir.cross(z).normalized()
		global_transform.basis = Basis(x, up_dir, z)
