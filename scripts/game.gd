extends Node
## Root: builds the world once behind a loading screen, then alternates between the main menu
## (cinematic flyby in the background) and flight sessions. Owns camera, HUD, pause menu.

var world: World
var camera: CameraRig
var hud: Hud
var menu: MainMenu
var session: Session
var bullets: Bullets

var _ui: CanvasLayer
var _loading: Control
var _loading_bar: ProgressBar
var _loading_label: Label
var _pause: Control
var _demo: Aircraft

const LIGHT := {"dawn": 0.6, "noon": 1.0, "sunset": 0.55, "night": 0.14}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	Controls.register()
	_ui = CanvasLayer.new()
	_ui.layer = 10
	add_child(_ui)
	_build_loading()
	await get_tree().process_frame
	await get_tree().process_frame
	Sfx.setup(self)

	camera = CameraRig.new()
	camera.process_mode = Node.PROCESS_MODE_PAUSABLE
	add_child(camera)
	camera.current = true

	world = World.new()
	world.process_mode = Node.PROCESS_MODE_PAUSABLE
	add_child(world)
	world.progress.connect(_on_progress)
	var tod: String = GameMode.load_value("time_of_day", "noon")
	await world.build(tod)
	Fx.light_level = LIGHT.get(tod, 1.0)

	bullets = Bullets.new()
	bullets.process_mode = Node.PROCESS_MODE_PAUSABLE
	add_child(bullets)

	var hud_layer := CanvasLayer.new()
	hud_layer.layer = 5
	add_child(hud_layer)
	hud = Hud.new()
	hud_layer.add_child(hud)

	menu = MainMenu.new()
	menu.world = world
	_ui.add_child(menu)
	menu.start_requested.connect(_start)
	menu.quit_requested.connect(func(): get_tree().quit())
	_build_pause()
	_loading.queue_free()
	_show_menu()


# ------------------------------------------------------------------ loading

func _build_loading() -> void:
	_loading = ColorRect.new()
	(_loading as ColorRect).color = Color(0.02, 0.03, 0.05)
	_loading.set_anchors_preset(Control.PRESET_FULL_RECT)
	_ui.add_child(_loading)
	var v := VBoxContainer.new()
	v.set_anchors_preset(Control.PRESET_CENTER)
	v.position = Vector2(-300, -80)
	v.custom_minimum_size = Vector2(600, 0)
	_loading.add_child(v)
	v.add_child(UiTheme.label("SKYBREAK", 64, Color.WHITE))
	_loading_label = UiTheme.label("Starting...", 18, Color(0.8, 0.85, 0.9))
	v.add_child(_loading_label)
	_loading_bar = ProgressBar.new()
	_loading_bar.max_value = 1.0
	_loading_bar.custom_minimum_size = Vector2(600, 14)
	_loading_bar.show_percentage = false
	v.add_child(_loading_bar)


func _on_progress(f: float, text: String) -> void:
	if is_instance_valid(_loading_bar):
		_loading_bar.value = f
		_loading_label.text = text


# ------------------------------------------------------------------ menu / sessions

func _show_menu() -> void:
	get_tree().paused = false
	_pause.visible = false
	if session != null:
		session.clear()
		session.queue_free()
		session = null
	Aircraft.wind = Vector3.ZERO
	hud.ac = null
	hud.pc = null
	hud.session = null
	menu.visible = true
	menu.refresh()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_spawn_demo()


func _spawn_demo() -> void:
	if _demo != null and is_instance_valid(_demo):
		_demo.queue_free()
	var c: Vector3 = world.cities[0].center
	var r := 3200.0
	var start := c + Vector3(r, 0, 0)
	start.y = 700.0
	_demo = Aircraft.new()
	_demo.setup("f16", 3, "default", "DEMO")
	add_child(_demo)
	_demo.place_in_air(Transform3D(Basis.looking_at(Vector3(0, 0, -1), Vector3.UP), start), 200.0)
	var ai := AIPilot.new()
	ai.role = "traffic"
	ai.cruise_alt = 700.0
	var route: Array[Vector3] = []
	for i in 8:
		var a := -TAU * i / 8.0
		route.append(c + Vector3(cos(a), 0, sin(a)) * r)
	ai.route = route
	_demo.add_child(ai)
	_demo.throttle = 0.8
	camera.cinematic = true
	camera.set_target(_demo)
	camera.set_mode(CameraRig.Mode.ORBIT)


func _start(cfg: Dictionary) -> void:
	if _demo != null and is_instance_valid(_demo):
		_demo.queue_free()
		_demo = null
	if cfg.time != world.time_of_day:
		world.set_time_of_day(cfg.time)
	Fx.light_level = LIGHT.get(cfg.time, 1.0)
	menu.visible = false
	camera.cinematic = false
	camera.set_mode(CameraRig.Mode.CHASE)
	session = Session.new()
	session.process_mode = Node.PROCESS_MODE_PAUSABLE
	add_child(session)
	session.start(cfg, world, hud, camera)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


# ------------------------------------------------------------------ pause

func _build_pause() -> void:
	_pause = Control.new()
	_pause.set_anchors_preset(Control.PRESET_FULL_RECT)
	_pause.theme = UiTheme.make()
	_pause.process_mode = Node.PROCESS_MODE_ALWAYS
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.45)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_pause.add_child(dim)
	var p := PanelContainer.new()
	p.position = Vector2(60, 60)
	_pause.add_child(p)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 30)
	p.add_child(h)
	var v := VBoxContainer.new()
	v.custom_minimum_size = Vector2(260, 0)
	v.add_theme_constant_override("separation", 10)
	h.add_child(v)
	v.add_child(UiTheme.label("PAUSED", 40, Color.WHITE))
	for item in [["Resume", _resume], ["Restart", _restart], ["Main menu", _show_menu], ["Quit", func(): get_tree().quit()]]:
		var b := Button.new()
		b.text = item[0]
		b.custom_minimum_size = Vector2(0, 44)
		b.pressed.connect(item[1])
		v.add_child(b)
	var cv := VBoxContainer.new()
	cv.add_child(UiTheme.header("CONTROLS"))
	cv.add_child(UiTheme.controls_grid())
	h.add_child(cv)
	_pause.visible = false
	_ui.add_child(_pause)


func _resume() -> void:
	_pause.visible = false
	get_tree().paused = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _restart() -> void:
	_resume()
	if session != null:
		session.restart()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and (event as InputEventKey).physical_keycode == KEY_F11:
		var fs := DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED if fs else DisplayServer.WINDOW_MODE_FULLSCREEN)
	if session == null:
		return
	if event.is_action_pressed("pause"):
		if _pause.visible:
			_resume()
		else:
			_pause.visible = true
			get_tree().paused = true
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event is InputEventMouseButton and event.pressed and not _pause.visible and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
