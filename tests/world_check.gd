extends SceneTree
## Headless World check: build time, airports, skyline course, bridge gate, spatial hash and collision vs visuals.
## Run: ~/.agents/bin/gt godot ~/Code/Skybreak -- --script res://tests/world_check.gd

var failures: Array[String] = []


func check(ok: bool, what: String) -> void:
	if not ok:
		failures.append(what)
		print("  FAIL: ", what)


func _initialize() -> void:
	create_timer(240.0).timeout.connect(func() -> void:
		print("FAIL (timeout)")
		quit(1))
	_run.call_deferred()


func _run() -> void:
	var world := World.new()
	root.add_child(world)
	var t0 := Time.get_ticks_msec()
	await world.build("noon")
	print("build time: %d ms" % (Time.get_ticks_msec() - t0))
	check(World.instance == world, "World.instance is set")
	check(world.sun != null and world.environment != null, "sun and environment exposed")

	# Airports.
	check(world.airports.size() == 4, "4 airports")
	for i in world.airports.size():
		var a: Dictionary = world.airports[i]
		for key in ["name", "code", "position", "heading_deg", "length", "width", "elevation", "military"]:
			check(a.has(key), "airport %d has %s" % [i, key])
		for rev in [false, true]:
			var t := world.runway_start_transform(i, rev)
			var fwd := -t.basis.z
			var h0 := world.height_at(t.origin.x, t.origin.z)
			var p1 := t.origin + fwd * 1000.0
			var h1 := world.height_at(p1.x, p1.z)
			check(absf(h0 - t.origin.y) < 1.0, "%s start (rev=%s) flat: h=%.2f y=%.2f" % [a.code, rev, h0, t.origin.y])
			check(absf(h1 - t.origin.y) < 1.0, "%s 1 km down runway flat: h=%.2f" % [a.code, h1])
			check(not world.is_over_water(t.origin.x, t.origin.z), "%s not over water" % a.code)
			var ap := world.approach_transform(i, 5000.0, rev)
			check(ap.origin.y > world.surface_height_at(ap.origin.x, ap.origin.z), "%s approach above ground" % a.code)
		print("  %s %s elev %.0f heading %.0f" % [a.code, a.name, a.elevation, a.heading_deg])

	# Cities.
	check(world.cities.size() >= 3, "3 cities")
	print("  buildings: %d, boxes: %d, trees: %d" % [world.building_count, world.buildings.size(), world.tree_count])
	check(world.building_count >= 400, "at least 400 buildings")
	var pc: int = world.city_building_counts.get("Port Calder", 0)
	check(pc >= 400 and pc <= 900, "Port Calder has 400-900 buildings (%d)" % pc)

	# Terrain shape.
	var peak := -INF
	for k in 4000:
		var x := randf_range(-20000.0, 20000.0)
		var z := randf_range(-20000.0, -7000.0)
		peak = maxf(peak, world.height_at(x, z))
	print("  highest sampled peak: %.0f m" % peak)
	check(peak > 1700.0 and peak < 2800.0, "mountain peaks 1800-2600 m (sampled %.0f)" % peak)
	check(world.is_over_water(0.0, 15000.0), "sea to the south")
	check(world.is_over_water(world.layout.strait_x(4000.0), 4000.0), "strait under the bridge")

	# Skyline course.
	var course := world.skyline_course()
	check(course.size() >= 18 and course.size() <= 30, "18-30 rings (got %d)" % course.size())
	for k in course.size():
		var p := course[k].origin
		var surf := world.surface_height_at(p.x, p.z)
		check(p.y > surf + 20.0, "ring %d above surface+20 (y %.0f, surface %.0f)" % [k, p.y, surf])
		for b in world.buildings_near(p, 25.0):
			check(false, "ring %d within 25 m of building %s" % [k, b])
		var nearest := INF
		for b in world.buildings:
			nearest = minf(nearest, p.distance_to(p.clamp(b.position, b.end)))
		check(nearest >= 25.0, "ring %d clearance %.1f m (brute force)" % [k, nearest])

	# Bridge gate.
	var g := world.bridge_gate
	check(g.has("center") and g.has("basis") and g.has("size"), "bridge_gate keys")
	var gc: Vector3 = g.center
	var deck_bottom := INF
	for b in world.buildings_near(gc + Vector3(0, 40, 0), 60.0):
		if b.position.y > gc.y:
			deck_bottom = minf(deck_bottom, b.position.y)
	check(deck_bottom < INF and gc.y < deck_bottom, "gate below deck (gate %.1f, deck bottom %.1f)" % [gc.y, deck_bottom])
	check(absf(gc.y - deck_bottom * 0.5) < 2.0, "gate half-way between water and deck")

	# buildings_near.
	var dt := Vector3(950.0, 50.0, 1850.0)
	var near := world.buildings_near(dt, 300.0)
	check(near.size() > 0, "buildings_near downtown finds buildings (%d)" % near.size())
	var t1 := Time.get_ticks_usec()
	for k in 100:
		world.buildings_near(dt + Vector3(k, 0, 0), 400.0)
	print("  buildings_near(400 m): %.1f us/call" % ((Time.get_ticks_usec() - t1) / 100.0))

	# Collision matches visuals.
	await physics_frame
	await physics_frame
	var space := world.get_world_3d().direct_space_state
	var probes := 0
	for p in world.street_probes.slice(0, 12):
		probes += 1
		_ray(space, p, "street", 0.15)
	for k in range(0, world.roof_probes.size(), maxi(1, world.roof_probes.size() / 12)):
		probes += 1
		_ray(space, world.roof_probes[k], "roof", 0.15)
	# Terrain away from towns: compare against height_at on slopes.
	var worst := 0.0
	for k in 60:
		var x := randf_range(-18000.0, 18000.0)
		var z := randf_range(-18000.0, -6000.0)
		var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(Vector3(x, 4000, z), Vector3(x, -200, z)))
		if hit:
			worst = maxf(worst, absf(hit.position.y - world.height_at(x, z)))
	print("  terrain ray vs height_at worst error: %.2f m" % worst)
	check(worst < 2.0, "terrain collision within 2 m of height_at on mountains")
	check(probes >= 10, "probed street and roof points")

	print("PASS" if failures.is_empty() else "FAIL (%d)" % failures.size())
	quit(0 if failures.is_empty() else 1)


func _ray(space: PhysicsDirectSpaceState3D, p: Vector3, what: String, tol: float) -> void:
	var q := PhysicsRayQueryParameters3D.create(Vector3(p.x, p.y + 500.0, p.z), Vector3(p.x, p.y - 50.0, p.z))
	q.collision_mask = 1
	var hit := space.intersect_ray(q)
	check(not hit.is_empty() and absf(hit.position.y - p.y) < tol,
		"%s ray at (%.0f, %.0f): hit %s expected %.2f" % [what, p.x, p.z, hit.get("position", "none"), p.y])
