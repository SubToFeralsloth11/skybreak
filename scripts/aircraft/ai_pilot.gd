class_name AIPilot
extends Node
## Computer pilot. Flies the same flight model as the player through the same inputs.
## Roles: "fighter" (dogfights, guns + missiles, defends against missiles) and "traffic" (cruises a route).

var ac: Aircraft
var role := "fighter"
var skill := 0.5 # 0 rookie .. 1 ace
var target: Aircraft
var route: Array[Vector3] = []
var route_index := 0
var cruise_alt := 3000.0
var patrol_center := Vector3.ZERO

var _missile_cd := 6.0
var _lock_time := 0.0
var _burst := 0.0
var _flare_cd := 0.0
var _retarget := 0.0
var _jink := Vector3.ZERO
var _jink_t := 0.0
var _react := 0.0
var _desired := Vector3.FORWARD


func _ready() -> void:
	ac = get_parent() as Aircraft
	_missile_cd = randf_range(4.0, 10.0)


## Bank-and-pull steering toward a world direction. Returns Vector3(pitch, roll, yaw) inputs.
static func steer(a: Aircraft, desired: Vector3, max_pull := 1.0) -> Vector3:
	var b := a.global_transform.basis
	var local := b.inverse() * desired.normalized()
	var ahead := -local.z
	var off_angle := acos(clampf(ahead, -1.0, 1.0))
	var roll_err := atan2(local.x, local.y)
	if off_angle < deg_to_rad(4.0):
		# Nearly on target: level the wings gently and fine-tune with rudder + pitch.
		roll_err = lerpf(-a.bank_angle() * 0.6, roll_err, off_angle / deg_to_rad(4.0))
	var roll := clampf(roll_err * 2.2, -1.0, 1.0)
	var pitch_err := atan2(local.y, maxf(ahead, 0.05))
	var pull := clampf(pitch_err * 5.0, -0.35, 1.0)
	if ahead < 0.0:
		pull = 1.0 # target behind: roll then pull hard
	pull *= clampf(1.0 - absf(roll_err) / 1.4, 0.0, 1.0) if off_angle > deg_to_rad(10.0) else 1.0
	var yaw := clampf(local.x * 4.0, -1.0, 1.0) if off_angle < deg_to_rad(8.0) else 0.0
	return Vector3(pull * max_pull, roll, yaw)


func _physics_process(dt: float) -> void:
	if ac == null or not ac.alive:
		if ac != null:
			ac.fire_gun = false
		return
	if role == "traffic":
		_traffic(dt)
	else:
		_fighter(dt)


func _terrain_escape() -> Vector3:
	## Returns a climb direction if the flight path is heading into terrain/buildings, else ZERO.
	var world := World.instance
	if world == null:
		return Vector3.ZERO
	var pos := ac.global_position
	var v := ac.linear_velocity
	var min_alt := lerpf(380.0, 160.0, skill) if role == "fighter" else 600.0
	var danger := false
	for t in [1.5, 3.0, 5.0]:
		var p: Vector3 = pos + v * t
		if p.y < world.surface_height_at(p.x, p.z) + min_alt * (0.5 if t > 2.0 else 0.8):
			danger = true
			break
	if pos.y - world.surface_height_at(pos.x, pos.z) < min_alt * 0.6:
		danger = true
	var probe := pos + v * 3.0
	for bb in world.buildings_near(probe, 160.0):
		if bb.grow(60.0).has_point(probe) or bb.grow(40.0).has_point(pos + v * 1.5):
			danger = true
			break
	if not danger:
		return Vector3.ZERO
	var flat := Vector3(v.x, 0.0, v.z).normalized()
	if flat.length_squared() < 0.1:
		flat = ac.forward()
	return (flat + Vector3.UP * 1.6).normalized()


func _fighter(dt: float) -> void:
	_retarget -= dt
	if _retarget <= 0.0 or target == null or not is_instance_valid(target) or not target.alive:
		_retarget = 3.0
		target = _pick_target()
	_flare_cd -= dt
	_missile_cd -= dt
	_react -= dt
	var pos := ac.global_position
	var speed := ac.airspeed
	var desired := ac.forward()
	var want_speed := lerpf(210.0, 250.0, skill)
	var max_pull := lerpf(0.75, 1.0, skill)
	ac.fire_gun = false

	# --- missile defence
	var threat: Missile = null
	for m in Missile.active:
		if is_instance_valid(m) and m.is_tracking(ac) and m.global_position.distance_to(pos) < 3500.0:
			threat = m
			break
	if threat != null:
		var los := (threat.global_position - pos).normalized()
		var beam := los.cross(Vector3.UP).normalized()
		if beam.dot(ac.forward()) < 0.0:
			beam = -beam
		desired = (beam + Vector3.DOWN * 0.25).normalized()
		want_speed = 400.0
		if _flare_cd <= 0.0 and threat.global_position.distance_to(pos) < lerpf(1200.0, 2200.0, skill):
			ac.drop_flare()
			_flare_cd = lerpf(0.9, 0.45, skill)
	elif target != null:
		var tp := target.global_position
		var tv := target.linear_velocity
		var to_t := tp - pos
		var dist := to_t.length()
		var nose_off := ac.forward().angle_to(to_t)
		var their_nose := target.forward().angle_to(-to_t)
		if nose_off > deg_to_rad(110.0) and their_nose < deg_to_rad(35.0) and dist < 1800.0:
			# Bandit on our six: hard break turn with jinks.
			_jink_t -= dt
			if _jink_t <= 0.0:
				_jink_t = randf_range(1.2, 2.5)
				_jink = Vector3(randf_range(-1, 1), randf_range(-0.4, 0.6), randf_range(-1, 1))
			var break_dir := to_t.cross(Vector3.UP).normalized()
			if break_dir.dot(ac.forward()) < 0.0:
				break_dir = -break_dir
			desired = (break_dir + _jink * 0.5).normalized()
			want_speed = 260.0
			max_pull = 1.0
		else:
			var t_flight := dist / 1050.0
			var lead := tp + tv * t_flight * lerpf(0.6, 1.0, skill)
			if dist > 2500.0:
				lead = tp + tv * 1.5
			desired = (lead - pos).normalized()
			if dist < 600.0:
				want_speed = clampf(tv.length() + 15.0, 150.0, 260.0)
			# Guns
			var aim_err := ac.forward().angle_to(lead - pos)
			var tolerance := deg_to_rad(lerpf(1.2, 2.8, skill)) + 6.0 / maxf(dist, 50.0)
			if dist < lerpf(700.0, 1000.0, skill) and aim_err < tolerance:
				_burst = randf_range(0.4, 0.9)
			if _burst > 0.0:
				_burst -= dt
				ac.fire_gun = aim_err < tolerance * 2.5
			# Missiles
			if ac.missiles_left > 0 and dist > 700.0 and dist < 3800.0 and nose_off < deg_to_rad(18.0):
				_lock_time += dt
				if _lock_time > lerpf(2.5, 1.2, skill) and _missile_cd <= 0.0:
					ac.fire_missile(target)
					_missile_cd = randf_range(10.0, 18.0) * lerpf(1.4, 0.8, skill)
					_lock_time = 0.0
			else:
				_lock_time = maxf(_lock_time - dt, 0.0)
	else:
		# Patrol orbit.
		var c := patrol_center
		var off := pos - c
		off.y = 0.0
		var tangent := off.normalized().cross(Vector3.UP)
		desired = (tangent + (c + Vector3(0, 2500, 0) - pos).normalized() * 0.4).normalized()
		want_speed = 200.0

	var escape := _terrain_escape()
	if escape != Vector3.ZERO:
		desired = escape
		max_pull = 1.0
		ac.fire_gun = false
	# Reaction delay: rookies update their plan less often.
	if _react <= 0.0:
		_desired = desired
		_react = lerpf(0.35, 0.05, skill)
	if escape != Vector3.ZERO:
		_desired = escape
	var s := steer(ac, _desired, max_pull)
	ac.input_pitch = s.x
	ac.input_roll = s.y
	ac.input_yaw = s.z
	ac.throttle = 1.1 if speed < want_speed - 40.0 else (1.0 if speed < want_speed else (0.6 if speed < want_speed + 60.0 else 0.3))
	ac.speedbrake = speed > want_speed + 120.0
	ac.gear_down = false


func _pick_target() -> Aircraft:
	var best: Aircraft = null
	var bd := INF
	for a in Aircraft.all:
		if a == ac or not a.alive or a.team == ac.team or a.team == 2:
			continue
		var d := a.global_position.distance_to(ac.global_position)
		if a.is_player:
			d *= 0.6
		if d < bd:
			bd = d
			best = a
	return best


func _traffic(_dt: float) -> void:
	var pos := ac.global_position
	if route.is_empty():
		return
	var wp := route[route_index]
	wp.y = cruise_alt
	var to := wp - pos
	if Vector2(to.x, to.z).length() < 1500.0:
		route_index = (route_index + 1) % route.size()
	var desired := to.normalized()
	desired.y = clampf((cruise_alt - pos.y) / 3000.0, -0.08, 0.1)
	var escape := _terrain_escape()
	if escape != Vector3.ZERO:
		desired = escape
	var s := steer(ac, desired.normalized(), 0.5)
	ac.input_pitch = s.x
	ac.input_roll = clampf(s.y, -0.6, 0.6)
	ac.input_yaw = 0.0
	var want := float(ac.spec.cruise_speed) * 0.95
	ac.throttle = clampf(0.75 + (want - ac.airspeed) * 0.02, 0.35, 1.0)
	ac.gear_down = false
	ac.flap_setting = 0
