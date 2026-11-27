class_name CameraRig
extends Camera3D
## Cockpit (first person), chase (third person), flyby and orbit cameras with mouse look,
## G-force head movement and trauma-based shake.

enum Mode { COCKPIT, CHASE, FLYBY, ORBIT }

static var instance: CameraRig

var target: Aircraft
var mode := Mode.CHASE
var look_yaw := 0.0
var look_pitch := 0.0
var zoom := 1.0
var mouse_sensitivity := 0.0025
var trauma := 0.0
var cinematic := false # menu background orbit

var _smooth_q := Quaternion.IDENTITY
var _head_offset := Vector3.ZERO
var _prev_vel := Vector3.ZERO
var _idle_look := 0.0
var _flyby_pos := Vector3.ZERO
var _flyby_timer := 0.0
var _orbit_angle := 0.0
var _noise := FastNoiseLite.new()
var _t := 0.0


func _enter_tree() -> void:
	instance = self


func _exit_tree() -> void:
	if instance == self:
		instance = null


func _ready() -> void:
	far = 60000.0
	near = 0.1
	fov = 70.0
	doppler_tracking = Camera3D.DOPPLER_TRACKING_PHYSICS_STEP
	_noise.frequency = 2.0


static func add_trauma(amount: float) -> void:
	if instance != null:
		instance.trauma = minf(instance.trauma + amount, 1.0)


static func shake_at(pos: Vector3, size: float) -> void:
	if instance == null:
		return
	var d := instance.global_position.distance_to(pos)
	add_trauma(clampf(size * 40.0 / maxf(d, 10.0), 0.0, 0.9))


func set_target(ac: Aircraft) -> void:
	if target != null and is_instance_valid(target):
		target.set_cockpit_view(false)
	target = ac
	look_yaw = 0.0
	look_pitch = 0.0
	if ac != null:
		_smooth_q = ac.global_transform.basis.get_rotation_quaternion()
		_prev_vel = ac.linear_velocity
	_apply_mode()


func set_mode(m: Mode) -> void:
	mode = m
	look_yaw = 0.0
	look_pitch = 0.0
	_flyby_timer = 0.0
	_apply_mode()


func cycle_mode() -> void:
	var next := (int(mode) + 1) % 3 # cockpit -> chase -> flyby
	set_mode(next as Mode)


func _apply_mode() -> void:
	var inside := mode == Mode.COCKPIT and target != null and target.alive
	if target != null and is_instance_valid(target):
		target.set_cockpit_view(inside)
	near = 0.04 if inside else 0.3
	Sfx.set_cockpit(inside)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var mm := event as InputEventMouseMotion
		look_yaw -= mm.relative.x * mouse_sensitivity
		look_pitch -= mm.relative.y * mouse_sensitivity
		look_yaw = clampf(look_yaw, -2.9, 2.9) if mode == Mode.COCKPIT else wrapf(look_yaw, -PI, PI)
		look_pitch = clampf(look_pitch, -1.1, 1.35)
		_idle_look = 0.0
	elif event is InputEventMouseButton and event.pressed:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			zoom = clampf(zoom * 0.9, 0.35, 4.0)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			zoom = clampf(zoom * 1.1, 0.35, 4.0)
		elif mb.button_index == MOUSE_BUTTON_MIDDLE:
			look_yaw = 0.0
			look_pitch = 0.0


func _process(delta: float) -> void:
	_t += delta
	trauma = maxf(trauma - delta * 1.2, 0.0)
	if target == null or not is_instance_valid(target):
		return
	# Gamepad right stick looks around.
	var rs := Vector2(Input.get_joy_axis(0, JOY_AXIS_RIGHT_X), Input.get_joy_axis(0, JOY_AXIS_RIGHT_Y))
	if rs.length() > 0.2:
		look_yaw -= rs.x * delta * 2.5
		look_pitch -= rs.y * delta * 2.0
		look_pitch = clampf(look_pitch, -1.1, 1.35)
		_idle_look = 0.0
	_idle_look += delta
	if _idle_look > 2.5 and not cinematic:
		look_yaw = lerp_angle(look_yaw, 0.0, delta * 2.0)
		look_pitch = lerpf(look_pitch, 0.0, delta * 2.0)

	var xf := target.get_global_transform_interpolated()
	if mode == Mode.COCKPIT and target.alive:
		_cockpit(xf, delta)
	elif cinematic or mode == Mode.ORBIT or not target.alive:
		_orbit(xf, delta)
	elif mode == Mode.FLYBY:
		_flyby(xf, delta)
	else:
		_chase(xf, delta)
	if mode == Mode.COCKPIT and not target.alive:
		_apply_mode()
	_shake()


func _cockpit(xf: Transform3D, delta: float) -> void:
	# Head is pushed by acceleration (felt G), limited, smoothed.
	var v := target.linear_velocity
	var accel := (v - _prev_vel) / maxf(delta, 1e-3)
	_prev_vel = v
	var local_acc := xf.basis.inverse() * (accel + Vector3(0, 9.81, 0))
	var want := Vector3(-local_acc.x * 0.0012, -(local_acc.y - 9.81) * 0.0016, local_acc.z * 0.0008)
	want = want.clamp(Vector3(-0.06, -0.09, -0.06), Vector3(0.06, 0.05, 0.08))
	_head_offset = _head_offset.lerp(want, clampf(delta * 6.0, 0.0, 1.0))
	var head: Vector3 = target.spec.pilot_head
	var basis := xf.basis * Basis.from_euler(Vector3(look_pitch, look_yaw, 0.0), EULER_ORDER_YXZ)
	# Leaning: looking back shifts the head sideways so the tail is visible.
	var lean := Vector3(-sin(look_yaw) * 0.12, 0.0, absf(sin(look_yaw)) * 0.06)
	global_transform = Transform3D(basis, xf * (head + _head_offset + lean))
	fov = lerpf(fov, 74.0, delta * 3.0)


func _chase(xf: Transform3D, delta: float) -> void:
	var q := xf.basis.get_rotation_quaternion()
	var k := 7.0 if target.type_id == "f16" else 4.0
	_smooth_q = _smooth_q.slerp(q, 1.0 - exp(-delta * k)).normalized()
	var sb := Basis(_smooth_q)
	var dist: float = float(target.spec.chase_distance) * zoom
	var orbit := Basis.from_euler(Vector3(look_pitch, look_yaw, 0.0), EULER_ORDER_YXZ)
	var offset := sb * (orbit * Vector3(0, dist * 0.2, dist))
	var pos := xf.origin + offset
	# Keep the camera above the ground.
	if World.instance != null:
		var gh := World.instance.surface_height_at(pos.x, pos.z) + 2.0
		pos.y = maxf(pos.y, gh)
	var look_at_pt := xf.origin + sb * Vector3(0, dist * 0.06, -dist * 0.3)
	var up_vec := sb.y.lerp(Vector3.UP, 0.25).normalized()
	global_transform = Transform3D(Basis.looking_at(look_at_pt - pos, up_vec), pos)
	var speed_fov := 68.0 + clampf((target.airspeed - 100.0) / 400.0, 0.0, 1.0) * 14.0
	fov = lerpf(fov, speed_fov, delta * 2.0)


func _flyby(xf: Transform3D, delta: float) -> void:
	_flyby_timer -= delta
	var v := target.linear_velocity
	var to_cam := _flyby_pos - xf.origin
	var passed := to_cam.dot(v) < 0.0 and to_cam.length() > 250.0
	if _flyby_timer <= 0.0 or passed or to_cam.length() > 2500.0:
		var ahead := v.normalized() * clampf(v.length() * 2.2, 150.0, 900.0)
		var side := v.normalized().cross(Vector3.UP).normalized() * randf_range(-60.0, 60.0)
		_flyby_pos = xf.origin + ahead + side + Vector3(0, randf_range(-20.0, 25.0), 0)
		if World.instance != null:
			_flyby_pos.y = maxf(_flyby_pos.y, World.instance.surface_height_at(_flyby_pos.x, _flyby_pos.z) + 3.0)
		_flyby_timer = 12.0
	var dir := xf.origin - _flyby_pos
	global_transform = Transform3D(Basis.looking_at(dir, Vector3.UP), _flyby_pos)
	var dist := dir.length()
	fov = clampf(rad_to_deg(2.0 * atan(40.0 / maxf(dist, 1.0))) * 2.0, 8.0, 70.0)


func _orbit(xf: Transform3D, delta: float) -> void:
	_orbit_angle += delta * (0.12 if cinematic else 0.2)
	var dist: float = float(target.spec.chase_distance) * zoom * (1.4 if cinematic else 1.8)
	var yaw := _orbit_angle + look_yaw
	var pitch := clampf(0.25 + look_pitch, -0.5, 1.3)
	var offset := Vector3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch)) * dist
	var pos := xf.origin + offset
	if World.instance != null:
		pos.y = maxf(pos.y, World.instance.surface_height_at(pos.x, pos.z) + 2.0)
	global_transform = Transform3D(Basis.looking_at(xf.origin - pos, Vector3.UP), pos)
	fov = lerpf(fov, 60.0, delta)


func _shake() -> void:
	var s := trauma * trauma
	if target != null and is_instance_valid(target) and target.alive:
		# Buffet near the stall / over-G / on rough ground.
		if target.stalled:
			s += 0.04
		if target.on_ground and target.airspeed > 20.0:
			s += 0.006 * clampf(target.airspeed / 80.0, 0.0, 1.0)
		if target.mach > 0.95 and target.mach < 1.05:
			s += 0.03
	if s <= 0.0001:
		return
	var amt := s * (0.035 if mode == Mode.COCKPIT else 0.06)
	rotate_object_local(Vector3.RIGHT, _noise.get_noise_2d(_t * 40.0, 1.0) * amt)
	rotate_object_local(Vector3.UP, _noise.get_noise_2d(_t * 40.0, 50.0) * amt)
	rotate_object_local(Vector3.FORWARD, _noise.get_noise_2d(_t * 40.0, 99.0) * amt * 0.6)
