class_name DogfightMode
extends GameMode
## Endless waves of hostile fighters over Port Calder. A wingman helps; rearm between waves.

var wave := 0
var kills := 0
var score := 0
var _next_wave := 3.0
var _over := false
var best := 0


func start() -> void:
	wave = 0
	kills = 0
	score = 0
	_over = false
	_next_wave = 4.0
	best = int(load_value("dogfight_best", 0))
	var w := s.world
	var c: Vector3 = w.cities[0].center
	var start := c + Vector3(-6000.0, 0.0, 4000.0)
	start.y = 2600.0
	var xf := Transform3D(Basis.looking_at((c - start) * Vector3(1, 0, 1), Vector3.UP), start)
	s.spawn_player(xf, false, 230.0)
	var wing_xf := xf
	wing_xf.origin += xf.basis.x * 120.0 + xf.basis.z * 80.0
	var wingman := s.spawn_ai("f16", 0, wing_xf, 230.0, "fighter", 0.65, "default", "VIPER 2")
	(wingman.get_child(wingman.get_child_count() - 1) as AIPilot).patrol_center = c
	s.hud.big("DOGFIGHT", "Bandits inbound. Guns, missiles, flares. Good hunting.", 4.0)


func _hostiles() -> int:
	var n := 0
	for a in s.ai_aircraft:
		if is_instance_valid(a) and a.alive and a.team == 1:
			n += 1
	return n


func tick(dt: float) -> void:
	if _over:
		return
	if _hostiles() == 0:
		_next_wave -= dt
		if _next_wave <= 0.0:
			_spawn_wave()
			_next_wave = 6.0


func _spawn_wave() -> void:
	wave += 1
	var p := s.player
	if p == null or not is_instance_valid(p):
		return
	if wave > 1:
		# Rearm (ground crew magic between waves), but damage stays.
		p.gun_ammo = int(p.spec.gun.ammo)
		var ok_missiles := 0
		for m in p.model.missiles:
			if not is_instance_valid(m):
				continue
			var holder: Node = (m as Node3D).get_parent()
			var pname := String(holder.name) if holder != null else ""
			if p.parts.has(pname) and p.parts[pname].attached:
				(m as Node3D).visible = true
				ok_missiles += 1
		p.missiles_left = ok_missiles
		p.flares_left = int(p.spec.flares)
		s.hud.message("REARMED: guns, missiles, flares", Hud.GREEN, 3.0)
	var count := mini(1 + wave, 6)
	var skill := clampf(0.25 + wave * 0.12, 0.25, 0.95)
	var base_dir := Vector3(randf_range(-1, 1), 0, randf_range(-1, 1)).normalized()
	for i in count:
		var dir := base_dir.rotated(Vector3.UP, (i - count * 0.5) * 0.25)
		var pos := p.global_position + dir * randf_range(6500.0, 8500.0)
		pos.y = clampf(p.global_position.y + randf_range(-500.0, 900.0), 1200.0, 5000.0)
		if s.world != null:
			pos.y = maxf(pos.y, s.world.surface_height_at(pos.x, pos.z) + 800.0)
		var xf := Transform3D(Basis.looking_at(p.global_position - pos, Vector3.UP), pos)
		var e := s.spawn_ai("f16", 1, xf, 240.0, "fighter", skill, "aggressor", "BANDIT %d-%d" % [wave, i + 1])
		if wave < 2:
			e.missiles_left = 0
		else:
			e.missiles_left = mini(wave - 1, 4)
	s.hud.big("WAVE %d" % wave, "%d bandit%s, skill %d%%" % [count, "s" if count > 1 else "", int(skill * 100)], 3.5)


func on_aircraft_destroyed(a: Aircraft) -> void:
	if a.team == 1 and a.kill_credit == s.player:
		kills += 1
		score += 100 * wave
	elif a.team == 1:
		score += 25 * wave


func on_player_destroyed() -> void:
	_over = true
	var total := score + (s.tricks.score if s.tricks != null else 0)
	var rec := ""
	if total > best:
		best = total
		save_value("dogfight_best", total)
		rec = "  NEW BEST!"
	s.hud.big("SHOT DOWN", "Wave %d, %d kills, score %d%s. Press R to fly again." % [wave, kills, total, rec], 8.0)


func hud_info() -> Dictionary:
	var lines: Array = [
		"Wave %d   Bandits %d" % [wave, _hostiles()],
		"Kills %d   Score %d" % [kills, score + (s.tricks.score if s.tricks != null else 0)],
		"Best %d" % best,
	]
	if _hostiles() == 0 and not _over:
		lines.append("Next wave in %d s" % int(ceil(_next_wave)))
	return {"title": "DOGFIGHT", "lines": lines}
