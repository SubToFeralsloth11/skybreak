extends SceneTree
## Headless flight-model checks: trim, pull/roll rates, takeoff run, landing-gear rest height.
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

	for t in ["f16", "airliner"]:
		print("== %s ==" % t)
		var spec := AircraftSpec.get_spec(t)
		# --- hands-off cruise trim
		var a := _spawn(t)
		var cruise: float = spec.cruise_speed
		a.place_in_air(Transform3D(Basis.IDENTITY, Vector3(0, 3000, 0)), cruise)
		a.throttle = 0.75 if t == "f16" else 0.7
		await _frames(120 * 15)
		print("  15s hands-off: alt %.0f m  v %.0f m/s  aoa %.1f°  pitch %.1f°  bank %.1f°  g %.2f  elev %.2f" % [
			a.global_position.y, a.airspeed, rad_to_deg(a.aoa), rad_to_deg(a.pitch_angle()), rad_to_deg(a.bank_angle()), a.g_load, a.elevator])
		_check(absf(a.global_position.y - 3000.0) < 250.0, "%s holds altitude hands-off (%.0f)" % [t, a.global_position.y])
		_check(absf(rad_to_deg(a.bank_angle())) < 5.0, "%s wings stay level" % t)
		# --- full pull
		var gmax := 0.0
		a.input_pitch = 1.0
		for i in 240:
			await physics_frame
			gmax = maxf(gmax, a.g_load)
		a.input_pitch = 0.0
		print("  full pull 2s: max G %.1f  aoa %.1f°  v %.0f" % [gmax, rad_to_deg(a.aoa), a.airspeed])
		var gl: float = spec.fbw.g_max
		_check(gmax > gl * 0.6 and gmax < gl * 1.25, "%s pull reaches ~G limit (%.1f / %.1f)" % [t, gmax, gl])
		await _frames(240)
		# --- roll rate
		var bank0 := a.bank_angle()
		a.input_roll = 1.0
		var maxp := 0.0
		for i in 120:
			await physics_frame
			maxp = maxf(maxp, -(a.global_transform.basis.inverse() * a.angular_velocity).z)
		a.input_roll = 0.0
		print("  roll 1s: max rate %.0f°/s (bank %.0f -> %.0f)" % [rad_to_deg(maxp), rad_to_deg(bank0), rad_to_deg(a.bank_angle())])
		var pr: float = spec.fbw.roll_rate_deg
		_check(rad_to_deg(maxp) > pr * 0.5, "%s roll rate (%.0f / %.0f)" % [t, rad_to_deg(maxp), pr])
		await _frames(240)
		print("  after release: bank %.1f°  p %.1f°/s" % [rad_to_deg(a.bank_angle()), rad_to_deg(-(a.global_transform.basis.inverse() * a.angular_velocity).z)])
		# --- max level speed at full power, 3000 m
		a.place_in_air(Transform3D(Basis.IDENTITY, Vector3(0, 3000, 0)), cruise)
		a.throttle = 1.1 if t == "f16" else 1.0
		await _frames(120 * 40)
		print("  40s full power: v %.0f m/s (M%.2f) alt %.0f" % [a.airspeed, a.mach, a.global_position.y])
		# --- slow flight / stall
		a.place_in_air(Transform3D(Basis.IDENTITY, Vector3(0, 3000, 0)), cruise * 0.7)
		a.throttle = 0.0
		a.input_pitch = 0.3
		var min_v := 999.0
		for i in 120 * 25:
			await physics_frame
			min_v = minf(min_v, a.airspeed)
			if i % 360 == 0:
				print("    t%2ds v %3.0f aoa %5.1f pitch %5.1f elev %5.2f q %5.1f°/s alt %4.0f stalled %s" % [i / 120, a.airspeed, rad_to_deg(a.aoa), rad_to_deg(a.pitch_angle()), a.elevator, rad_to_deg((a.global_transform.basis.inverse() * a.angular_velocity).x), a.global_position.y, a.stalled])
		print("  idle + slight back stick 25s: min v %.0f m/s, aoa %.1f°, stalled %s, alt %.0f" % [min_v, rad_to_deg(a.aoa), a.stalled, a.global_position.y])
		a.queue_free()
		await _frames(2)

		# --- ground: rest + takeoff
		var g := _spawn(t)
		g.place_on_ground(Transform3D(Basis.IDENTITY, Vector3(0, 0, 0)))
		await _frames(240)
		var rest_y := g.global_position.y
		print("  on gear: y %.2f (expected %.2f) contacts %d pitch %.1f°" % [rest_y, g.rest_height(), g.wheels_in_contact, rad_to_deg(g.pitch_angle())])
		_check(g.wheels_in_contact == 3 and absf(rest_y - g.rest_height()) < 0.35, "%s rests on its gear" % t)
		g.brake = 1.0
		await _frames(240)
		_check(absf(g.linear_velocity.length()) < 0.5, "%s stays put at idle with brakes" % t)
		g.brake = 0.0
		g.throttle = 1.1 if t == "f16" else 1.0
		var vr: float = spec.v_rotate
		var lift_off_v := -1.0
		var dist0 := g.global_position
		for i in 120 * 70:
			await physics_frame
			if g.airspeed > vr:
				g.input_pitch = 0.6
			if g.wheels_in_contact == 0 and g.global_position.y > rest_y + 3.0 and lift_off_v < 0.0:
				lift_off_v = g.airspeed
				print("  lift-off at %.0f m/s after %.0f m" % [lift_off_v, g.global_position.distance_to(dist0)])
			if i % 600 == 0:
				print("    t%2ds v %3.0f pitch %5.1f elev %5.2f contacts %d alt %5.1f alive %s health %.2f" % [i / 120, g.airspeed, rad_to_deg(g.pitch_angle()), g.elevator, g.wheels_in_contact, g.global_position.y, g.alive, g.total_health()])
			if lift_off_v > 0.0 and g.global_position.y > 150.0:
				break
		_check(lift_off_v > 0.0, "%s takes off" % t)
		_check(g.alive, "%s survives takeoff" % t)
		print("  climb: alt %.0f v %.0f pitch %.1f" % [g.global_position.y, g.airspeed, rad_to_deg(g.pitch_angle())])
		g.queue_free()
		await _frames(2)

	print("RESULT: %s" % ("PASS" if failures.is_empty() else "FAIL " + str(failures)))
	quit(0 if failures.is_empty() else 1)
