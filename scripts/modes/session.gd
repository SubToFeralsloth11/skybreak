class_name Session
extends Node3D
## One flight: spawns the player and AI aircraft, runs the selected game mode, tricks and respawns.

signal request_menu

var cfg: Dictionary
var world: World
var hud: Hud
var camera: CameraRig
var player: Aircraft
var pc: PlayerController
var tricks: Tricks
var mode: GameMode
var ai_aircraft: Array[Aircraft] = []
var elapsed := 0.0
var _dead_timer := -1.0


func start(p_cfg: Dictionary, p_world: World, p_hud: Hud, p_camera: CameraRig) -> void:
	cfg = p_cfg
	world = p_world
	hud = p_hud
	camera = p_camera
	pc = PlayerController.new()
	add_child(pc)
	pc.message.connect(func(t, c): hud.message(t, c))
	match String(cfg.mode):
		"dogfight":
			mode = DogfightMode.new()
		"skyline":
			mode = SkylineMode.new()
		"route", "landing":
			mode = RouteMode.new()
		_:
			mode = FreeFlightMode.new()
	mode.s = self
	hud.session = self
	hud.pc = pc
	mode.start()


## Spawn the player aircraft at a transform; on_ground places it on its gear.
func spawn_player(xform: Transform3D, on_ground: bool, speed := 0.0) -> Aircraft:
	if player != null and is_instance_valid(player):
		player.queue_free()
	var a := Aircraft.new()
	a.setup(cfg.aircraft, 0, "default", "VIPER 1" if cfg.aircraft == "f16" else "SKYBREAK 101")
	add_child(a)
	if on_ground:
		a.place_on_ground(xform)
	else:
		a.place_in_air(xform, speed)
	player = a
	pc.bind(a)
	pc.enabled = true
	hud.ac = a
	camera.set_target(a)
	tricks = Tricks.new(a)
	tricks.trick.connect(func(n, p): hud.popup("%s  +%d" % [n, p]); Sfx.play("chime", -10.0, 1.2))
	a.destroyed.connect(_on_player_destroyed)
	a.part_lost.connect(func(_ac, part): hud.message(part.to_upper().replace("_", " ") + " LOST", Hud.RED, 4.0))
	a.touchdown.connect(func(_ac, vs): mode.on_touchdown(vs))
	_dead_timer = -1.0
	return a


func spawn_ai(type_id: String, team: int, xform: Transform3D, speed: float, role := "fighter", skill := 0.5, livery := "default", callsign := "") -> Aircraft:
	var a := Aircraft.new()
	a.setup(type_id, team, livery, callsign)
	add_child(a)
	a.place_in_air(xform, speed)
	var ai := AIPilot.new()
	ai.role = role
	ai.skill = skill
	a.add_child(ai)
	a.destroyed.connect(_on_ai_destroyed)
	ai_aircraft.append(a)
	return a


func _on_ai_destroyed(a: Aircraft) -> void:
	if a.kill_credit == player and player != null:
		hud.message("SPLASH! %s destroyed" % a.callsign, Hud.GREEN, 3.5)
	mode.on_aircraft_destroyed(a)
	# Clean the wreck away after a while.
	get_tree().create_timer(40.0, false).timeout.connect(func():
		if is_instance_valid(a):
			ai_aircraft.erase(a)
			a.queue_free())


func _on_player_destroyed(_a: Aircraft) -> void:
	pc.stop_all_sounds()
	camera.set_mode(CameraRig.Mode.CHASE)
	_dead_timer = 0.0
	mode.on_player_destroyed()


func _physics_process(dt: float) -> void:
	elapsed += dt
	if tricks != null:
		tricks.tick(dt)
	mode.tick(dt)
	if _dead_timer >= 0.0:
		_dead_timer += dt


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("camera"):
		camera.cycle_mode()
		var names := ["COCKPIT", "CHASE", "FLYBY", "ORBIT"]
		hud.message("VIEW: " + names[camera.mode], Hud.WHITE, 1.5)
	elif event.is_action_pressed("toggle_hud"):
		hud.show_hud = not hud.show_hud
	elif event.is_action_pressed("restart"):
		restart()


func restart() -> void:
	clear()
	mode.start()


func clear() -> void:
	for a in ai_aircraft:
		if is_instance_valid(a):
			a.queue_free()
	ai_aircraft.clear()
	if player != null and is_instance_valid(player):
		player.queue_free()
	player = null
	for c in get_children():
		if c is Missile or c is Flare or c is Debris:
			c.queue_free()
	if Bullets.instance != null:
		Bullets.instance.clear()
	elapsed = 0.0


func hud_info() -> Dictionary:
	return mode.hud_info()


func nearest_airport(pos: Vector3) -> int:
	var best := 0
	var bd := INF
	for i in world.airports.size():
		var d: float = (world.airports[i].position as Vector3).distance_to(pos)
		if d < bd:
			bd = d
			best = i
	return best


## Runway-relative coordinates: x = lateral offset, y = height above runway, z = distance along from centre.
func runway_local(airport: int, pos: Vector3) -> Vector3:
	var ap: Dictionary = world.airports[airport]
	var h := deg_to_rad(ap.heading_deg)
	var dir := Vector3(sin(h), 0, -cos(h))
	var right := Vector3(cos(h), 0, sin(h))
	var rel: Vector3 = pos - (ap.position as Vector3)
	return Vector3(rel.dot(right), rel.y, rel.dot(dir))


func on_runway(airport: int, pos: Vector3) -> bool:
	var ap: Dictionary = world.airports[airport]
	var l := runway_local(airport, pos)
	return absf(l.x) < float(ap.width) * 0.5 + 2.0 and absf(l.z) < float(ap.length) * 0.5
