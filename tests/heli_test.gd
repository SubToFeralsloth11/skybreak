extends SceneTree
## Headless helicopter checks: hover, flip, inverted hang.
## Run: ~/.agents/bin/gt godot ~/Code/Skybreak -- --headless --script res://tests/flight_test.gd

var failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _check(cond: bool, what: String) -> void:
	print(("  ok   " if cond else "  FAIL ") + what)
	if not cond:
		failures.append(what)


func _frames(n: int) -> void:
	for i in n:
		await physics_frame


func _spawn(type_id: String) -> Aircraft:
	var a := Aircraft.new()
	a.setup(type_id, 0)
	root.add_child(a)
	return a


func _run() -> void:
	Sfx.setup(root)
	var floor := StaticBody3D.new()
	floor.collision_layer = 1
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(20000, 2, 20000)
	cs.shape = box
	cs.position = Vector3(0, -1, 0)
	floor.add_child(cs)
	root.add_child(floor)
	await _frames(2)
	# ---------------- helicopter: hover, flip, inverted hang
	print("heli")
	var hl := _spawn("heli")
	await _frames(2)
	hl.place_in_air(Transform3D(Basis.IDENTITY, Vector3(0, 300, 0)), 0.0)
	await _frames(240)
	_check(absf(hl.linear_velocity.y) < 3.0, "heli hovers at hover collective (vy %.1f)" % hl.linear_velocity.y)
	hl.input_pitch = 1.0
	var flip_frames := 0
	for i in 480:
		await physics_frame
		flip_frames += 1
		if hl.global_transform.basis.y.y < -0.9:
			break
	hl.input_pitch = 0.0
	_check(flip_frames < 420, "heli half-flips in %.2f s" % (flip_frames / 120.0))
	hl.throttle = 0.0 # full negative collective while upside down
	for i in 360:
		await physics_frame
		if not is_instance_valid(hl) or not hl.alive:
			break
		if i % 60 == 0:
			print("    inv t%d up.y %.2f vy %.1f alt %.0f col %.2f rpm %.2f" % [i, hl.global_transform.basis.y.y, hl.linear_velocity.y, hl.global_position.y, hl.collective, hl.engine_rpm[0]])
	if not is_instance_valid(hl) or not hl.alive:
		_check(false, "heli survives inverted")
		print("RESULT: FAIL " + str(failures))
		quit(1)
		return
	print("  inverted: up.y %.2f vy %.1f alt %.0f" % [hl.global_transform.basis.y.y, hl.linear_velocity.y, hl.global_position.y])
	_check(hl.global_transform.basis.y.y < -0.8 and hl.linear_velocity.y > -4.0, "heli holds altitude inverted")
	hl.queue_free()
	await _frames(2)

	var fw := _spawn("heli")
	await _frames(2)
	fw.place_in_air(Transform3D(Basis.IDENTITY, Vector3(0, 400, 0)), 0.0)
	fw.heli_drive = 1.0
	var t5 := 0.0
	for i in 120 * 20:
		await physics_frame
		fw.input_pitch = clampf((deg_to_rad(-38.0) - fw.pitch_angle()) * 2.5 - fw.angular_velocity.dot(fw.global_transform.basis.x) * 0.6, -1.0, 1.0)
		if i == 600:
			t5 = fw.airspeed
	print("  forward: 5s %.0f m/s, 20s %.0f m/s, alt %.0f" % [t5, fw.airspeed, fw.global_position.y])
	_check(fw.airspeed > 60.0 and absf(fw.global_position.y - 400.0) < 120.0, "heli reaches speed and holds height")

	print("RESULT: %s" % ("PASS" if failures.is_empty() else "FAIL " + str(failures)))
	quit(0 if failures.is_empty() else 1)
