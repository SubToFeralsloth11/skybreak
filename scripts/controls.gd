class_name Controls
extends RefCounted
## Registers all input actions at startup (keyboard, mouse, gamepad).

const HELP := [
	["W / S", "Pitch down / up"],
	["A / D", "Roll left / right"],
	["Q / E", "Rudder left / right (nose-wheel steering on ground)"],
	["Shift / Ctrl", "Throttle up / down (past 100% = afterburner)"],
	["Space / Left mouse", "Cannon"],
	["X / Right mouse", "Missile (lock with growl -> tone)"],
	["T", "Cycle target"],
	["C", "Flares"],
	["G", "Landing gear"],
	["F", "Flaps (0-1-2-3)"],
	["B (hold)", "Wheel brakes / speed brakes"],
	["P", "Flight-control protections ON/OFF"],
	["V", "Camera: cockpit / chase / flyby"],
	["Mouse", "Look around (wheel: zoom, middle: centre)"],
	["M", "Mouse-aim steering (arcade) on/off"],
	["H", "Toggle HUD"],
	["R", "Restart / respawn"],
	["Esc", "Pause menu"],
]


static func register() -> void:
	_add("pitch_down", [KEY_W, KEY_UP], [], [[JOY_AXIS_LEFT_Y, -1.0]])
	_add("pitch_up", [KEY_S, KEY_DOWN], [], [[JOY_AXIS_LEFT_Y, 1.0]])
	_add("roll_left", [KEY_A, KEY_LEFT], [], [[JOY_AXIS_LEFT_X, -1.0]])
	_add("roll_right", [KEY_D, KEY_RIGHT], [], [[JOY_AXIS_LEFT_X, 1.0]])
	_add("yaw_left", [KEY_Q], [JOY_BUTTON_LEFT_SHOULDER], [])
	_add("yaw_right", [KEY_E], [JOY_BUTTON_RIGHT_SHOULDER], [])
	_add("throttle_up", [KEY_SHIFT, KEY_EQUAL, KEY_KP_ADD], [JOY_BUTTON_DPAD_UP], [])
	_add("throttle_down", [KEY_CTRL, KEY_MINUS, KEY_KP_SUBTRACT], [JOY_BUTTON_DPAD_DOWN], [])
	_add("fire_gun", [KEY_SPACE], [], [[JOY_AXIS_TRIGGER_RIGHT, 1.0]], [MOUSE_BUTTON_LEFT])
	_add("fire_missile", [KEY_X, KEY_ENTER], [], [[JOY_AXIS_TRIGGER_LEFT, 1.0]], [MOUSE_BUTTON_RIGHT])
	_add("cycle_target", [KEY_T], [JOY_BUTTON_X], [])
	_add("flares", [KEY_C], [JOY_BUTTON_A], [])
	_add("gear", [KEY_G], [JOY_BUTTON_B], [])
	_add("flaps", [KEY_F], [JOY_BUTTON_DPAD_RIGHT], [])
	_add("brake", [KEY_B], [JOY_BUTTON_DPAD_LEFT], [])
	_add("protections", [KEY_P], [], [])
	_add("camera", [KEY_V], [JOY_BUTTON_Y], [])
	_add("mouse_aim", [KEY_M], [], [])
	_add("toggle_hud", [KEY_H], [], [])
	_add("restart", [KEY_R], [JOY_BUTTON_BACK], [])
	_add("pause", [KEY_ESCAPE], [JOY_BUTTON_START], [])


static func _add(action: String, keys: Array, buttons: Array, axes: Array, mouse := []) -> void:
	if InputMap.has_action(action):
		InputMap.erase_action(action)
	InputMap.add_action(action, 0.2)
	for k in keys:
		var e := InputEventKey.new()
		e.physical_keycode = k
		InputMap.action_add_event(action, e)
	for b in buttons:
		var j := InputEventJoypadButton.new()
		j.button_index = b
		InputMap.action_add_event(action, j)
	for a in axes:
		var m := InputEventJoypadMotion.new()
		m.axis = a[0]
		m.axis_value = a[1]
		InputMap.action_add_event(action, m)
	for mb in mouse:
		var e2 := InputEventMouseButton.new()
		e2.button_index = mb
		InputMap.action_add_event(action, e2)
