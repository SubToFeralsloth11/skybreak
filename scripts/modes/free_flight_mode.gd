class_name FreeFlightMode
extends GameMode
## Fly anywhere. Airline traffic shares the sky; stunts score points.


func start() -> void:
	var w := s.world
	var spawn: String = s.cfg.get("spawn", "air")
	if spawn.begins_with("runway:"):
		var idx := int(spawn.split(":")[1])
		s.spawn_player(w.runway_start_transform(idx), true)
		s.hud.message("%s Tower: runway %s, cleared for take-off" % [w.airports[idx].name, RouteMode.runway_number(w.airports[idx].heading_deg)], Hud.WHITE, 6.0)
	else:
		# Over Port Calder, heading for downtown.
		var city: Dictionary = w.cities[0]
		var c: Vector3 = city.center
		var start := c + Vector3(0, 0, 9000.0)
		start.y = maxf(w.surface_height_at(start.x, start.z), 0.0) + 900.0
		var xf := Transform3D(Basis.looking_at(Vector3(c.x, start.y - 300.0, c.z) - start, Vector3.UP), start)
		s.spawn_player(xf, false, {"f16": 200.0, "heli": 40.0}.get(s.cfg.aircraft, 150.0))
	_spawn_traffic()


func _spawn_traffic() -> void:
	var w := s.world
	if w.airports.size() < 2:
		return
	for i in 4:
		var a: Dictionary = w.airports[i % w.airports.size()]
		var b: Dictionary = w.airports[(i + 1) % w.airports.size()]
		var pa: Vector3 = a.position
		var pb: Vector3 = b.position
		var alt := 2200.0 + i * 600.0
		var pos := pa.lerp(pb, randf_range(0.2, 0.6))
		pos.y = alt
		var dir := (pb - pa)
		dir.y = 0.0
		var xf := Transform3D(Basis.looking_at(dir.normalized(), Vector3.UP), pos)
		var ac := s.spawn_ai("airliner", 2, xf, 210.0, "traffic", 0.5, "default", "SKB%d" % (200 + i * 17))
		var ai: AIPilot = ac.get_child(ac.get_child_count() - 1)
		ai.cruise_alt = alt
		var r: Array[Vector3] = []
		for k in w.airports.size():
			r.append(w.airports[(i + 1 + k) % w.airports.size()].position)
		ai.route = r


func hud_info() -> Dictionary:
	var lines: Array = []
	if s.tricks != null:
		lines.append("Stunt score: %d" % s.tricks.score)
		if s.tricks.combo > 1.0:
			lines.append("Combo x%.1f" % s.tricks.combo)
	if s.player != null and is_instance_valid(s.player):
		var idx := s.nearest_airport(s.player.global_position)
		var ap: Dictionary = s.world.airports[idx]
		lines.append("Nearest: %s (%s) %.1f km" % [ap.name, ap.code, (ap.position as Vector3).distance_to(s.player.global_position) / 1000.0])
	return {"title": "FREE FLIGHT", "lines": lines}


func on_player_destroyed() -> void:
	s.hud.big("CRASHED", "Press R to fly again", 5.0)
