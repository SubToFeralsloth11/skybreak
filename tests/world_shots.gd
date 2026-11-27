extends SceneTree
## Renders reference views of the world to /tmp/skybreak_shots/ (needs a real renderer, not --headless).
## Run: ~/.agents/bin/heavy 240 godot --path ~/Code/Skybreak --script res://tests/world_shots.gd
## Optional user arg: -- only=<name> to render a single shot.

const OUT := "/tmp/skybreak_shots/"


func _initialize() -> void:
	create_timer(220.0).timeout.connect(func() -> void:
		print("world_shots: timeout")
		quit(1))
	_run.call_deferred()


func _shot(cam: Camera3D, from: Vector3, at: Vector3, file: String, frames := 40) -> void:
	cam.global_position = from
	cam.look_at(at, Vector3.UP)
	for k in frames:
		await process_frame
	await RenderingServer.frame_post_draw
	var img := root.get_texture().get_image()
	img.save_png(OUT + file)
	print("saved ", OUT + file)


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(OUT)
	var only := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("only="):
			only = a.substr(5)
	var world := World.new()
	root.add_child(world)
	var cam := Camera3D.new()
	cam.far = 60000.0
	cam.near = 0.5
	cam.fov = 65.0
	root.add_child(cam)
	cam.make_current()
	await world.build("noon")
	var xs := world.layout.strait_x(4000.0)
	var shots := [
		["downtown_canyon.png", Vector3(2300.0, 72.0, 2080.0), Vector3(1000.0, 60.0, 2080.0), "noon"],
		["bridge_low.png", Vector3(xs + 250.0, 14.0, 2900.0), Vector3(xs, 70.0, 4000.0), "noon"],
		["runway_threshold.png", Vector3(), Vector3(), "noon"],
		["mountains_1500.png", Vector3(3500.0, 1500.0, -4500.0), Vector3(2500.0, 900.0, -14000.0), "noon"],
		["coast_4000.png", Vector3(4000.0, 4000.0, 16000.0), Vector3(0.0, 0.0, 2000.0), "noon"],
		["calder_night.png", Vector3(3800.0, 420.0, 5600.0), Vector3(600.0, 90.0, 2000.0), "night"],
		["calder_sunset.png", Vector3(-4200.0, 300.0, 5200.0), Vector3(600.0, 120.0, 2200.0), "sunset"],
	]
	for s in shots:
		if only != "" and not String(s[0]).begins_with(only):
			continue
		world.set_time_of_day(s[3])
		var from: Vector3 = s[1]
		var at: Vector3 = s[2]
		if s[0] == "runway_threshold.png":
			var t := world.runway_start_transform(0)
			var fwd := -t.basis.z
			from = t.origin - fwd * 700.0 + Vector3(0, 38.0, 0)
			at = t.origin + fwd * 900.0
		await _shot(cam, from, at, s[0])
	quit(0)
