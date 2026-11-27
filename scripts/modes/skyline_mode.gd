class_name SkylineMode
extends GameMode
## Timed ring course through the downtown canyons and under the bridge.

const RING_RADIUS := 22.0

var rings: Array[Transform3D] = []
var ring_nodes: Array[MeshInstance3D] = []
var current := 0
var started := false
var finished := false
var t := 0.0
var penalty := 0.0
var best := 0.0
var _prev_along := -1.0
var _mat_next: StandardMaterial3D
var _mat_later: StandardMaterial3D
var _mat_done: StandardMaterial3D


func start() -> void:
	current = 0
	started = false
	finished = false
	t = 0.0
	penalty = 0.0
	_prev_along = -1.0
	best = float(load_value("skyline_best_" + String(s.cfg.aircraft), 0.0))
	rings = s.world.skyline_course()
	_build_rings()
	var r0 := rings[0]
	var fwd := -r0.basis.z
	var flat := Vector3(fwd.x, 0, fwd.z).normalized()
	var pos := r0.origin - flat * 1400.0
	pos.y = maxf(r0.origin.y, s.world.surface_height_at(pos.x, pos.z) + 120.0)
	var xf := Transform3D(Basis.looking_at(r0.origin - pos, Vector3.UP), pos)
	s.spawn_player(xf, false, 170.0 if s.cfg.aircraft == "f16" else 125.0)
	s.hud.big("SKYLINE RUN", "%d rings through Port Calder. Missed ring = +5 s." % rings.size(), 4.0)


func _build_rings() -> void:
	for n in ring_nodes:
		if is_instance_valid(n):
			n.queue_free()
	ring_nodes.clear()
	_mat_next = _ring_mat(Color(1.0, 0.55, 0.1), 4.0)
	_mat_later = _ring_mat(Color(0.3, 0.7, 1.0), 1.2)
	_mat_done = _ring_mat(Color(0.3, 1.0, 0.4), 0.6)
	var torus := TorusMesh.new()
	torus.inner_radius = RING_RADIUS - 1.2
	torus.outer_radius = RING_RADIUS + 1.2
	torus.rings = 48
	torus.ring_segments = 10
	for r in rings:
		var mi := MeshInstance3D.new()
		mi.mesh = torus
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		s.add_child(mi)
		# Torus axis is local Y: rotate so it faces along the course (-Z).
		mi.global_transform = Transform3D(r.basis * Basis(Vector3.RIGHT, PI * 0.5), r.origin)
		ring_nodes.append(mi)
	_refresh()


func _ring_mat(c: Color, e: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.emission_enabled = true
	m.emission = c
	m.emission_energy_multiplier = e
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return m


func _refresh() -> void:
	for i in ring_nodes.size():
		var mi := ring_nodes[i]
		if i < current:
			mi.material_override = _mat_done
			mi.visible = i >= current - 2
		elif i == current:
			mi.material_override = _mat_next
			mi.visible = true
		else:
			mi.material_override = _mat_later
			mi.visible = i < current + 6


func tick(dt: float) -> void:
	if finished or s.player == null or not is_instance_valid(s.player) or not s.player.alive:
		return
	if started:
		t += dt
	if current >= rings.size():
		return
	var r := rings[current]
	var fwd := -r.basis.z
	var rel := s.player.global_position - r.origin
	var along := rel.dot(fwd)
	if _prev_along < 0.0 and along >= 0.0:
		var lateral := (rel - fwd * along).length()
		if lateral < RING_RADIUS * 1.1:
			Sfx.play("chime", -6.0)
			s.hud.popup("RING %d/%d" % [current + 1, rings.size()], Color(0.4, 1.0, 0.5))
			if s.tricks != null:
				s.tricks.score += 100
		else:
			penalty += 5.0
			s.hud.message("MISSED RING +5 s", Hud.RED, 2.0)
		_advance()
	elif along > 900.0:
		penalty += 5.0
		s.hud.message("MISSED RING +5 s", Hud.RED, 2.0)
		_advance()
	else:
		_prev_along = along


func _advance() -> void:
	if current == 0:
		started = true
	current += 1
	_prev_along = -1.0
	if current < rings.size():
		var r := rings[current]
		_prev_along = (s.player.global_position - r.origin).dot(-r.basis.z)
		if _prev_along >= 0.0:
			_prev_along = -1.0
	else:
		_finish()
	_refresh()


func _finish() -> void:
	finished = true
	var total := t + penalty
	var rec := ""
	if best <= 0.0 or total < best:
		best = total
		save_value("skyline_best_" + String(s.cfg.aircraft), total)
		rec = "NEW RECORD! "
	s.hud.big("FINISH  " + fmt_time(total), "%s%s penalties. Stunt score %d. R to retry." % [rec, fmt_time(penalty), s.tricks.score if s.tricks != null else 0], 10.0)


func on_player_destroyed() -> void:
	s.hud.big("CRASHED", "Ring %d of %d. Press R to retry." % [current + 1, rings.size()], 6.0)


func hud_info() -> Dictionary:
	var lines: Array = [
		"Time %s  (+%d s)" % [fmt_time(t), int(penalty)],
		"Ring %d / %d" % [mini(current + 1, rings.size()), rings.size()],
		"Best %s" % (fmt_time(best) if best > 0.0 else "--"),
	]
	if s.tricks != null:
		lines.append("Stunts %d" % s.tricks.score)
	var info := {"title": "SKYLINE RUN", "lines": lines}
	if current < rings.size():
		info["waypoint"] = rings[current].origin
		info["waypoint_label"] = "RING"
	return info
