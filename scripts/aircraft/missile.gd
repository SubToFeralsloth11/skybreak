class_name Missile
extends Node3D
## Short-range infrared missile: boost-sustain motor, lead-pursuit guidance with G limit,
## seeker field-of-view, flare seduction, proximity fuse, ground/building impact.

static var active: Array[Missile] = []

var shooter: Aircraft
var target: Node3D
var vel := Vector3.ZERO
var age := 0.0
var motor_time := 3.6
var boost_accel := 185.0
var max_g := 38.0
var lifetime := 20.0
var fuse := 9.0
var seeker_half_fov := deg_to_rad(45.0)
var _checked_flares := {}
var _plume: Node3D
var _detonated := false


func launch(p_shooter: Aircraft, start: Vector3, basis_in: Basis, p_vel: Vector3, p_target: Node3D) -> void:
	shooter = p_shooter
	target = p_target
	global_position = start
	global_transform.basis = basis_in
	vel = p_vel - basis_in.y * 6.0 # rail/ejection drop
	var body := Node3D.new()
	add_child(body)
	var mesh := AircraftModel._missile_mesh(Vector3(0, 0, -1.45), 2.9, 0.064,
		AircraftModel.std(Color(0.86, 0.86, 0.84), 0.2, 0.45), AircraftModel.std(Color(0.25, 0.35, 0.45), 0.6, 0.1))
	body.add_child(mesh)
	_plume = Fx.missile_plume()
	_plume.position = Vector3(0, 0, 1.5)
	add_child(_plume)
	for c in _plume.get_children():
		if c is GPUParticles3D:
			(c as GPUParticles3D).emitting = true
	active.append(self)
	Sfx.play_at("missile", start, 0.8)


func _exit_tree() -> void:
	active.erase(self)


func is_tracking(ac: Node3D) -> bool:
	return not _detonated and target == ac


func _physics_process(dt: float) -> void:
	if _detonated:
		return
	age += dt
	var pos := global_position
	var speed := vel.length()
	var dir := vel / maxf(speed, 1.0)
	var rho := 1.225 * exp(-maxf(pos.y, 0.0) / 8500.0)

	if age > 0.2 and age < motor_time:
		vel += -global_transform.basis.z * boost_accel * dt
	vel -= vel * speed * 0.00004 * (rho / 1.225) * dt
	vel.y -= 9.81 * dt

	# Seeker: lose the target if it leaves the field of view or dies.
	if target != null and is_instance_valid(target):
		if target is Aircraft and not (target as Aircraft).alive and not (target as Aircraft).fires.size() > 0:
			target = null
	else:
		target = null
	if target != null:
		var los := (target.global_position - pos).normalized()
		if age > 0.6 and dir.angle_to(los) > seeker_half_fov:
			target = null
	_check_flares(pos, dir)

	# Guidance: lead pursuit with G-limited turning (after clearing the launcher).
	if target != null and age > 0.35:
		var tpos := target.global_position
		var tvel := _target_velocity()
		var rel := tpos - pos
		var closing := maxf(speed - tvel.dot(rel.normalized()), 120.0)
		var t_go := rel.length() / closing
		var aim := tpos + tvel * t_go * 0.9 + Vector3(0, 0.5 * 9.81 * t_go * t_go * 0.3, 0)
		var want := (aim - pos).normalized()
		var max_turn := max_g * 9.81 * clampf(speed / 500.0, 0.25, 1.0) / maxf(speed, 50.0) * dt
		var ang := dir.angle_to(want)
		if ang > 1e-4:
			var axis := dir.cross(want).normalized()
			if axis.length_squared() > 0.5:
				vel = vel.rotated(axis, minf(ang, max_turn))
				vel *= 1.0 - minf(ang, max_turn) * 0.15 # induced drag of hard turns

	var new_pos := pos + vel * dt
	# Collision sweep against world + aircraft.
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(pos, new_pos, 1 | 2)
	if shooter != null and is_instance_valid(shooter) and age < 1.5:
		q.exclude = [shooter.get_rid()]
	var hit := space.intersect_ray(q)
	if not hit.is_empty():
		global_position = hit.position
		_detonate()
		return
	# Proximity fuse: closest approach on this step's segment.
	if target != null and is_instance_valid(target) and age > 0.5:
		var tp := target.global_position
		var seg := new_pos - pos
		var t := clampf((tp - pos).dot(seg) / maxf(seg.length_squared(), 1e-4), 0.0, 1.0)
		var closest := pos + seg * t
		if closest.distance_to(tp) < fuse:
			global_position = closest
			_detonate()
			return
	if World.instance != null and new_pos.y < World.instance.surface_height_at(new_pos.x, new_pos.z):
		global_position = new_pos
		_detonate()
		return
	global_position = new_pos
	if vel.length_squared() > 1.0:
		look_at(new_pos + vel, Vector3.UP if absf(vel.normalized().y) < 0.98 else Vector3.RIGHT)
	if age > motor_time:
		for c in _plume.get_children():
			if c is GPUParticles3D:
				(c as GPUParticles3D).emitting = false
			elif c is OmniLight3D:
				(c as OmniLight3D).visible = false
	if age > lifetime:
		_detonate()


func _target_velocity() -> Vector3:
	if target is RigidBody3D:
		return (target as RigidBody3D).linear_velocity
	if target is Flare:
		return (target as Flare).vel
	return Vector3.ZERO


func _check_flares(pos: Vector3, dir: Vector3) -> void:
	if target == null or not (target is Aircraft):
		return
	for f in Flare.active:
		if _checked_flares.has(f) or not is_instance_valid(f):
			continue
		var to := f.global_position - pos
		if to.length() > 3000.0 or dir.angle_to(to.normalized()) > seeker_half_fov:
			continue
		_checked_flares[f] = true
		# Each flare inside the seeker's view has a chance to steal the lock; harder head-on.
		var aspect := dir.dot((target as Aircraft).forward())
		var chance := 0.32 if aspect > 0.0 else 0.2
		if randf() < chance:
			target = f
			return


func _detonate() -> void:
	if _detonated:
		return
	_detonated = true
	var pos := global_position
	Fx.explosion(get_parent(), pos, 0.55, vel * 0.1)
	for ac in Aircraft.all:
		if ac.global_position.distance_to(pos) < 40.0:
			ac.blast(pos, 26.0, 270.0, shooter)
	for c in _plume.get_children():
		if c is GPUParticles3D:
			(c as GPUParticles3D).emitting = false
	for c in get_children():
		if c != _plume:
			c.queue_free()
	active.erase(self)
	# Keep the smoke trail alive until it fades.
	get_tree().create_timer(7.0, false).timeout.connect(queue_free)
