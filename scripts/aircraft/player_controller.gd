class_name PlayerController
extends Node
## Turns keyboard/mouse/gamepad input into aircraft controls, handles targeting, missile lock tones,
## and missile-launch warnings.

signal message(text: String, color: Color)

var ac: Aircraft
var selected_target: Aircraft
var lock_progress := 0.0
var locked := false
var mouse_aim := false
var aim_dir := Vector3.FORWARD
var incoming_missile := false
var enabled := true

var _pitch := 0.0
var _roll := 0.0
var _yaw := 0.0
var _snd_growl: AudioStreamPlayer
var _snd_lock: AudioStreamPlayer
var _snd_warn: AudioStreamPlayer
var _snd_caution: AudioStreamPlayer
var _target_list_index := 0


func _ready() -> void:
	_snd_growl = Sfx.loop_2d("growl", -14.0)
	_snd_lock = Sfx.loop_2d("lock", -12.0)
	_snd_warn = Sfx.loop_2d("warning", -8.0)
	_snd_caution = Sfx.loop_2d("caution", -12.0)


func bind(aircraft: Aircraft) -> void:
	ac = aircraft
	ac.is_player = true
	selected_target = null
	locked = false
	lock_progress = 0.0
	aim_dir = ac.forward()


func _exit_tree() -> void:
	for p in [_snd_growl, _snd_lock, _snd_warn, _snd_caution]:
		if is_instance_valid(p):
			p.queue_free()


func _unhandled_input(event: InputEvent) -> void:
	if ac == null or not enabled:
		return
	if event.is_action_pressed("gear"):
		ac.gear_down = not ac.gear_down
		message.emit("GEAR DOWN" if ac.gear_down else "GEAR UP", Color(0.7, 1, 0.7))
	elif event.is_action_pressed("flaps"):
		ac.flap_setting = (ac.flap_setting + 1) % 4
		message.emit("FLAPS %d" % ac.flap_setting, Color(0.7, 1, 0.7))
	elif event.is_action_pressed("protections"):
		ac.fbw_override = not ac.fbw_override
		message.emit("PROTECTIONS OFF - you can overstress the airframe" if ac.fbw_override else "PROTECTIONS ON", Color(1, 0.7, 0.3) if ac.fbw_override else Color(0.7, 1, 0.7))
	elif event.is_action_pressed("flares"):
		if ac.flares_left > 0:
			ac.drop_flare()
		else:
			message.emit("NO FLARES", Color(1, 0.5, 0.4))
	elif event.is_action_pressed("cycle_target"):
		_cycle_target()
	elif event.is_action_pressed("fire_missile"):
		_fire_missile()
	elif event.is_action_pressed("mouse_aim"):
		mouse_aim = not mouse_aim
		aim_dir = ac.forward()
		if CameraRig.instance != null:
			CameraRig.instance.look_yaw = 0.0
			CameraRig.instance.look_pitch = 0.0
		message.emit("MOUSE AIM ON - point the camera, the plane follows" if mouse_aim else "MOUSE AIM OFF", Color(0.7, 0.9, 1))


func _physics_process(dt: float) -> void:
	if ac == null or not is_instance_valid(ac):
		return
	if not ac.alive or not enabled:
		ac.fire_gun = false
		_stop_tones()
		return
	var tp := Input.get_action_strength("pitch_up") - Input.get_action_strength("pitch_down")
	var tr := Input.get_action_strength("roll_right") - Input.get_action_strength("roll_left")
	var ty := Input.get_action_strength("yaw_right") - Input.get_action_strength("yaw_left")
	# Keyboard ramps like a real stick; analogue sticks pass straight through.
	_pitch = _ramp(_pitch, tp, dt)
	_roll = _ramp(_roll, tr, dt)
	_yaw = _ramp(_yaw, ty, dt)
	if mouse_aim and CameraRig.instance != null and CameraRig.instance.mode != CameraRig.Mode.FLYBY:
		var cam := CameraRig.instance
		aim_dir = -cam.global_transform.basis.z
		if cam.mode == CameraRig.Mode.CHASE:
			# Aim where the camera looks (ahead of the aircraft).
			aim_dir = (cam.global_position + aim_dir * 2000.0 - ac.global_position).normalized()
		var s := AIPilot.steer(ac, aim_dir, 1.0)
		ac.input_pitch = clampf(s.x + _pitch, -1.0, 1.0)
		ac.input_roll = clampf(s.y + _roll, -1.0, 1.0)
		ac.input_yaw = clampf(s.z + _yaw, -1.0, 1.0)
	else:
		ac.input_pitch = _pitch
		ac.input_roll = _roll
		ac.input_yaw = _yaw
	if ac.spec.has("heli"):
		# Cyclic is delicate: square the stick for fine control near centre.
		ac.input_pitch *= absf(ac.input_pitch)
		ac.input_roll *= absf(ac.input_roll)
		ac.input_yaw *= absf(ac.input_yaw) * 0.8 + 0.2
		# Arrow keys: fly forward/back. Nose tilts to a set angle and the rotor pulls you along.
		var drive := float(Input.is_physical_key_pressed(KEY_UP)) - float(Input.is_physical_key_pressed(KEY_DOWN))
		ac.heli_drive = move_toward(ac.heli_drive, drive, dt * 1.5)
		if drive != 0.0:
			var want_pitch := deg_to_rad(-38.0 if drive > 0.0 else 25.0)
			ac.input_pitch = clampf((want_pitch - ac.pitch_angle()) * 2.5 - ac.angular_velocity.dot(ac.global_transform.basis.x) * 0.6, -1.0, 1.0)
	var thr_rate := (0.6 if ac.spec.has("heli") else 0.45) * dt
	if Input.is_action_pressed("throttle_up"):
		var cap := 1.1 if ac.spec.has_afterburner else 1.0
		ac.throttle = minf(ac.throttle + thr_rate, cap)
	if Input.is_action_pressed("throttle_down"):
		ac.throttle = maxf(ac.throttle - thr_rate, 0.0)
	ac.brake = Input.get_action_strength("brake")
	ac.speedbrake = Input.is_action_pressed("brake") and not ac.on_ground
	ac.fire_gun = Input.is_action_pressed("fire_gun") and ac.gun_ammo > 0
	_update_lock(dt)
	_update_warnings()


func _ramp(cur: float, target: float, dt: float) -> float:
	if absf(target) > 0.01 and absf(target) < 0.99:
		return target # analogue
	var rate := 3.0 if absf(target) > absf(cur) else 5.0
	return move_toward(cur, target, rate * dt)


func _candidates() -> Array[Aircraft]:
	var out: Array[Aircraft] = []
	for a in Aircraft.all:
		if a != ac and a.alive and a.team != ac.team and a.team != 2:
			out.append(a)
	return out


func _cycle_target() -> void:
	var list := _candidates()
	if list.is_empty():
		selected_target = null
		return
	list.sort_custom(func(x, y): return x.global_position.distance_to(ac.global_position) < y.global_position.distance_to(ac.global_position))
	_target_list_index = (_target_list_index + 1) % list.size()
	selected_target = list[_target_list_index]
	lock_progress = 0.0
	locked = false


func _update_lock(dt: float) -> void:
	if ac.missiles_left <= 0:
		lock_progress = 0.0
		locked = false
		_stop_tones()
		if selected_target == null or not selected_target.alive:
			selected_target = _best_in_cone(deg_to_rad(60.0), 8000.0)
		return
	if selected_target != null and (not is_instance_valid(selected_target) or not selected_target.alive):
		selected_target = null
	# Seeker looks for a heat source near the nose.
	var seeker_target := _best_in_cone(deg_to_rad(22.0), 5500.0)
	if selected_target != null and _in_cone(selected_target, deg_to_rad(22.0), 5500.0):
		seeker_target = selected_target
	if seeker_target != null:
		if seeker_target != selected_target:
			selected_target = seeker_target
			lock_progress = 0.0
		lock_progress = minf(lock_progress + dt / 1.1, 1.0)
	else:
		lock_progress = maxf(lock_progress - dt * 2.0, 0.0)
		if selected_target == null:
			selected_target = _best_in_cone(deg_to_rad(80.0), 9000.0)
	locked = lock_progress >= 1.0 and seeker_target != null
	if locked:
		if not _snd_lock.playing:
			_snd_lock.play()
		_snd_growl.stop()
	elif seeker_target != null:
		if not _snd_growl.playing:
			_snd_growl.play()
		_snd_lock.stop()
	else:
		_stop_tones()


func _in_cone(a: Aircraft, half: float, rng: float) -> bool:
	var to := a.global_position - ac.global_position
	return to.length() < rng and ac.forward().angle_to(to) < half


func _best_in_cone(half: float, rng: float) -> Aircraft:
	var best: Aircraft = null
	var ba := INF
	for a in _candidates():
		var to := a.global_position - ac.global_position
		if to.length() > rng:
			continue
		var ang := ac.forward().angle_to(to)
		if ang < half and ang < ba:
			ba = ang
			best = a
	return best


func _fire_missile() -> void:
	if ac.missiles_left <= 0:
		message.emit("NO MISSILES", Color(1, 0.5, 0.4))
		return
	ac.fire_missile(selected_target if locked else null)
	message.emit("FOX TWO" if locked else "FOX TWO (no lock)", Color(1, 0.9, 0.5))
	lock_progress = 0.0
	locked = false


func _stop_tones() -> void:
	if _snd_growl != null:
		_snd_growl.stop()
		_snd_lock.stop()


func _update_warnings() -> void:
	incoming_missile = false
	for m in Missile.active:
		if is_instance_valid(m) and m.is_tracking(ac):
			incoming_missile = true
			break
	if incoming_missile and not _snd_warn.playing:
		_snd_warn.play()
	elif not incoming_missile and _snd_warn.playing:
		_snd_warn.stop()
	var caution := ac.stalled and not ac.on_ground and ac.airspeed > 10.0
	if ac.agl < 120.0 and ac.vertical_speed < -25.0 and not ac.on_ground and ac.agl < -ac.vertical_speed * 4.0:
		caution = true
	if caution and not _snd_caution.playing:
		_snd_caution.play()
	elif not caution and _snd_caution.playing:
		_snd_caution.stop()


func stop_all_sounds() -> void:
	_stop_tones()
	if _snd_warn != null:
		_snd_warn.stop()
		_snd_caution.stop()
