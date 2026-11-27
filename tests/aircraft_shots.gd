extends SceneTree
## Renders the aircraft models (exterior, cockpit, damage, explosion) to PNGs for visual review.
## Run windowed: ~/.agents/bin/heavy 120 godot --path ~/Code/Skybreak --script res://tests/aircraft_shots.gd

const OUT := "/tmp/skybreak_shots"


func _initialize() -> void:
	_run.call_deferred()


func _shot(name: String) -> void:
	for i in 6:
		await process_frame
	await RenderingServer.frame_post_draw
	var img := root.get_viewport().get_texture().get_image()
	img.save_png("%s/%s.png" % [OUT, name])
	print("saved ", name)


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(OUT)
	create_timer(100.0).timeout.connect(func(): quit(1))
	root.size = Vector2i(1280, 720)
	Sfx.setup(root)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	sky.sky_material = ProceduralSkyMaterial.new()
	e.sky = sky
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	e.glow_enabled = true
	e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.environment = e
	root.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(-0.8, 0.6, 0)
	sun.shadow_enabled = true
	root.add_child(sun)
	var ground := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(400, 400)
	ground.mesh = pm
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.25, 0.26, 0.27)
	ground.material_override = gm
	root.add_child(ground)
	var cam := Camera3D.new()
	cam.far = 5000
	root.add_child(cam)
	cam.current = true

	for t in ["f16", "airliner"]:
		var a := Aircraft.new()
		a.setup(t, 0)
		root.add_child(a)
		a.freeze = true
		var h := a.rest_height()
		a.global_position = Vector3(0, h, 0)
		var s := 1.0 if t == "f16" else 2.6
		cam.fov = 55
		cam.look_at_from_position(Vector3(14, 5, -14) * s, Vector3(0, h, 0))
		await _shot(t + "_front34")
		cam.look_at_from_position(Vector3(-16, 7, 16) * s, Vector3(0, h, 0))
		await _shot(t + "_rear34")
		cam.look_at_from_position(Vector3(0.01, 30, 0) * s, Vector3(0, 0, 0))
		await _shot(t + "_top")
		cam.look_at_from_position(Vector3(20, 1.2, 0) * s, Vector3(0, h, 0))
		await _shot(t + "_side")
		# Controls deflected + gear retracting + afterburner
		a.elevator = 1.0
		a.aileron = 1.0
		a.rudder = 1.0
		a.flap_pos = 1.0
		a.ab_level = 1.0
		a.engine_rpm[0] = 1.0
		a.alive = true
		cam.look_at_from_position(Vector3(-12, 5, 18) * s, Vector3(0, h, 2))
		a._animate_model(0.016)
		a._update_effects(0.016)
		await _shot(t + "_controls")
		# Cockpit
		a.set_cockpit_view(true)
		var head: Vector3 = a.spec.pilot_head
		cam.fov = 74
		cam.near = 0.04
		cam.global_transform = Transform3D(Basis.IDENTITY, a.global_transform * head)
		cam.look_at(a.global_transform * (head + Vector3(0, -0.1, -10)))
		await _shot(t + "_cockpit")
		cam.global_transform = Transform3D(Basis.IDENTITY, a.global_transform * head)
		cam.look_at(a.global_transform * (head + Vector3(-10, -2, 2)))
		await _shot(t + "_cockpit_left")
		a.set_cockpit_view(false)
		cam.near = 0.05
		# Damage: lose left wing, engine fire
		a.detach_part("wing_l")
		var eng: String = a.spec.engines[0].part
		a._damage_part(eng, float(a.parts[eng].max) * 0.8, null)
		await process_frame
		for i in 40:
			await physics_frame
		cam.fov = 55
		cam.look_at_from_position(Vector3(16, 9, 18) * s, Vector3(0, h, 0))
		await _shot(t + "_damaged")
		a.queue_free()
		for d in root.get_children():
			if d is Debris:
				d.queue_free()
		await process_frame
	Fx.explosion(root, Vector3(0, 10, 0), 2.0)
	cam.look_at_from_position(Vector3(70, 25, 70), Vector3(0, 12, 0))
	for i in 20:
		await process_frame
	await _shot("explosion")
	quit(0)
