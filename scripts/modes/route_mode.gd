class_name RouteMode
extends GameMode
## Cross-country: take off, fly to another airport, land and stop on its runway.
## Landing challenge: start on final approach (with crosswind) and land.

enum Phase { TAKEOFF, ENROUTE, APPROACH, ROLLOUT, DONE, FAILED }

var phase := Phase.TAKEOFF
var from := 0
var to := 1
var landing_only := false
var touchdown_fpm := 0.0
var touchdown_offset := 0.0
var touchdown_dist := 0.0
var _touched := false
var _bounces := 0
var _start_t := 0.0
var best := 0


func start() -> void:
	var w := s.world
	landing_only = s.cfg.mode == "landing"
	from = int(s.cfg.get("from", 0))
	to = int(s.cfg.get("to", 1))
	if to == from and w.airports.size() > 1:
		to = (from + 1) % w.airports.size()
	_touched = false
	_bounces = 0
	_start_t = 0.0
	best = int(load_value("landing_best", 0))
	Aircraft.wind = Vector3.ZERO
	var dest: Dictionary = w.airports[to]
	if landing_only:
		var ang := randf() * TAU
		var kts := randf_range(4.0, 14.0)
		Aircraft.wind = Vector3(cos(ang), 0, sin(ang)) * kts * 0.5144
		var xf := w.approach_transform(to, 9000.0)
		var spd := 72.0 if s.cfg.aircraft == "airliner" else 80.0
		var a := s.spawn_player(xf, false, spd)
		a.gear_down = true
		a.gear_pos = 1.0
		a.flap_setting = 3 if s.cfg.aircraft == "airliner" else 1
		a.flap_pos = a.flap_setting / 3.0
		a.throttle = 0.55 if s.cfg.aircraft == "airliner" else 0.5
		for i in a.engine_rpm.size():
			a.engine_rpm[i] = a.throttle
		phase = Phase.APPROACH
		var wind_from := fposmod(rad_to_deg(atan2(-Aircraft.wind.x, Aircraft.wind.z)), 360.0)
		s.hud.big("LANDING CHALLENGE", "%s runway %s. Wind %03d° at %d kt. Gear down, flaps set." % [dest.name, runway_number(dest.heading_deg), int(wind_from), int(kts)], 6.0)
	else:
		s.spawn_player(w.runway_start_transform(from), true)
		phase = Phase.TAKEOFF
		var dep: Dictionary = w.airports[from]
		s.hud.big("CROSS-COUNTRY", "%s  ->  %s  (%.0f km)" % [dep.code, dest.code, (dep.position as Vector3).distance_to(dest.position) / 1000.0], 5.0)
		s.hud.message("%s Tower: runway %s, wind calm, cleared for take-off" % [dep.name, runway_number(dep.heading_deg)], Hud.WHITE, 7.0)


static func runway_number(heading: float) -> String:
	var n := int(round(fposmod(heading, 360.0) / 10.0))
	if n == 0:
		n = 36
	return str(n).pad_zeros(2)


func tick(dt: float) -> void:
	var p := s.player
	if p == null or not is_instance_valid(p) or not p.alive:
		return
	_start_t += dt
	var w := s.world
	var dest: Dictionary = w.airports[to]
	var dist := (dest.position as Vector3).distance_to(p.global_position)
	match phase:
		Phase.TAKEOFF:
			if not p.on_ground and p.agl > 150.0:
				phase = Phase.ENROUTE
				s.hud.message("Departure: climb and proceed to %s. Contact approach 15 km out." % dest.name, Hud.WHITE, 6.0)
		Phase.ENROUTE:
			if dist < 15000.0:
				phase = Phase.APPROACH
				s.hud.message("%s Approach: cleared ILS runway %s. Gear and flaps!" % [dest.name, runway_number(dest.heading_deg)], Hud.WHITE, 7.0)
		Phase.APPROACH:
			if p.on_ground:
				if s.on_runway(to, p.global_position):
					phase = Phase.ROLLOUT
				elif p.airspeed < 30.0:
					_fail("Landed off the runway")
		Phase.ROLLOUT:
			if not p.on_ground and p.agl > 3.0:
				_bounces += 1
				phase = Phase.APPROACH
			elif p.airspeed < 3.0:
				_complete()
			elif not s.on_runway(to, p.global_position) and p.airspeed < 40.0:
				_fail("Ran off the runway")


func on_touchdown(vs: float) -> void:
	if phase != Phase.APPROACH or _touched:
		return
	var p := s.player
	if not s.on_runway(to, p.global_position):
		return
	_touched = true
	touchdown_fpm = vs * 196.85
	var l := s.runway_local(to, p.global_position)
	var dest: Dictionary = s.world.airports[to]
	touchdown_offset = absf(l.x)
	touchdown_dist = l.z + float(dest.length) * 0.5
	var verdict := "BUTTER!" if touchdown_fpm < 120.0 else ("Smooth" if touchdown_fpm < 300.0 else ("Firm" if touchdown_fpm < 600.0 else "HARD"))
	s.hud.popup("TOUCHDOWN %d fpm  %s" % [int(touchdown_fpm), verdict], Color(0.6, 1, 0.7) if touchdown_fpm < 300.0 else Hud.AMBER)


func _complete() -> void:
	phase = Phase.DONE
	var score := 1000
	score -= int(clampf(touchdown_fpm - 100.0, 0.0, 900.0))
	score -= int(touchdown_offset * 15.0)
	score -= int(clampf(absf(touchdown_dist - 400.0) - 200.0, 0.0, 2000.0) * 0.2)
	score -= _bounces * 150
	score -= int((1.0 - s.player.total_health()) * 500.0)
	score = maxi(score, 0)
	var rec := ""
	if score > best:
		best = score
		save_value("landing_best", score)
		rec = "  NEW BEST!"
	var stars := "★★★" if score > 850 else ("★★☆" if score > 600 else ("★☆☆" if score > 300 else "☆☆☆"))
	s.hud.big("LANDED  %s" % stars, "Score %d%s  |  %d fpm, %.1f m off centreline, %d m from threshold. R to fly again." % [score, rec, int(touchdown_fpm), touchdown_offset, int(touchdown_dist)], 12.0)
	Sfx.play("chime", -4.0, 0.8)


func _fail(reason: String) -> void:
	phase = Phase.FAILED
	s.hud.big("FAILED", reason + ". Press R to retry.", 8.0)


func on_player_destroyed() -> void:
	if phase != Phase.DONE:
		phase = Phase.FAILED
		s.hud.big("CRASHED", "Press R to retry.", 6.0)


func hud_info() -> Dictionary:
	var w := s.world
	var dest: Dictionary = w.airports[to]
	var lines: Array = []
	var p := s.player
	var info := {"title": "LANDING CHALLENGE" if landing_only else "CROSS-COUNTRY"}
	if p == null or not is_instance_valid(p):
		info["lines"] = lines
		return info
	var dist := (dest.position as Vector3).distance_to(p.global_position)
	var gs := Vector2(p.linear_velocity.x, p.linear_velocity.z).length()
	lines.append("To %s (%s) rwy %s" % [dest.name, dest.code, runway_number(dest.heading_deg)])
	lines.append("Dist %.1f km   ETE %s" % [dist / 1000.0, fmt_time(dist / maxf(gs, 1.0)) if gs > 20.0 else "--"])
	match phase:
		Phase.TAKEOFF:
			lines.append("Full power, rotate at %d kt, gear up after lift-off" % int(float(p.spec.v_rotate) * 1.94384))
		Phase.ENROUTE:
			lines.append("Cruise: follow the diamond")
		Phase.APPROACH, Phase.ROLLOUT:
			var thr := w.approach_transform(to, 0.0).origin
			var rl := s.runway_local(to, p.global_position)
			var dist_thr := Vector2(p.global_position.x - thr.x, p.global_position.z - thr.z).length()
			var gs_alt := thr.y + tan(deg_to_rad(3.0)) * dist_thr
			var dev := p.global_position.y - gs_alt
			var gs_txt := "ON GLIDESLOPE" if absf(dev) < 8.0 else ("HIGH %d ft" % int(dev * 3.28) if dev > 0.0 else "LOW %d ft" % int(-dev * 3.28))
			var loc_txt := "ON CENTRELINE" if absf(rl.x) < 10.0 else ("FLY LEFT %d m" % int(rl.x) if rl.x > 0.0 else "FLY RIGHT %d m" % int(-rl.x))
			lines.append("%s   %s" % [gs_txt, loc_txt])
			lines.append("Target %d kt, gear %s, flaps %d" % [int((float(p.spec.stall_speed) * 1.3) * 1.94384), "DOWN" if p.gear_down else "UP!", p.flap_setting])
			if Aircraft.wind.length() > 0.5:
				var wind_from := fposmod(rad_to_deg(atan2(-Aircraft.wind.x, Aircraft.wind.z)), 360.0)
				lines.append("Wind %03d° / %d kt" % [int(wind_from), int(Aircraft.wind.length() * 1.944)])
			if phase == Phase.ROLLOUT:
				lines.append("Brakes (B), throttle idle, stop on the runway")
		Phase.DONE:
			lines.append("Arrived. Welcome to %s." % dest.name)
	info["lines"] = lines
	if phase in [Phase.TAKEOFF, Phase.ENROUTE]:
		info["waypoint"] = w.approach_transform(to, 10000.0).origin
		info["waypoint_label"] = dest.code + " FAF"
	elif phase == Phase.APPROACH:
		info["waypoint"] = w.approach_transform(to, 0.0).origin
		info["waypoint_label"] = "RWY " + runway_number(dest.heading_deg)
	return info
