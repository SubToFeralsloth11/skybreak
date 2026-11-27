class_name Hud
extends Control
## Head-up display drawn in 2D but conformal to the 3D world (pitch ladder, flight-path marker,
## target boxes and gun pipper are projected through the active camera). Also: speed/altitude tapes,
## heading tape, engine/gear/flap state, weapons, radar scope, damage diagram, warnings, G blackout.

const GREEN := Color(0.35, 1.0, 0.5, 0.95)
const AMBER := Color(1.0, 0.75, 0.25, 0.95)
const RED := Color(1.0, 0.25, 0.2, 0.95)
const WHITE := Color(0.95, 0.97, 1.0, 0.95)
const SHADOW := Color(0, 0, 0, 0.45)

var ac: Aircraft
var pc: PlayerController
var session: Node # GameSession (duck-typed: hud_info())
var show_hud := true

var _font: Font
var _messages: Array = [] # [text, color, time_left]
var _blackout := 0.0
var _redout := 0.0
var _g_timer := 0.0
var _t := 0.0
var _big_text := ""
var _big_sub := ""
var _big_time := 0.0
var _popup: Array = [] # trick popups [text, color, t]


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_font = ThemeDB.fallback_font


func message(text: String, color := WHITE, time := 3.0) -> void:
	_messages.push_front([text, color, time])
	if _messages.size() > 5:
		_messages.resize(5)


func popup(text: String, color := Color(1, 0.85, 0.3)) -> void:
	_popup.push_front([text, color, 2.2])
	if _popup.size() > 4:
		_popup.resize(4)


func big(text: String, sub := "", time := 4.0) -> void:
	_big_text = text
	_big_sub = sub
	_big_time = time


func _process(delta: float) -> void:
	_t += delta
	for m in _messages:
		m[2] -= delta
	_messages = _messages.filter(func(m): return m[2] > 0.0)
	for p in _popup:
		p[2] -= delta
	_popup = _popup.filter(func(p): return p[2] > 0.0)
	_big_time -= delta
	_update_gforce(delta)
	queue_redraw()


func _update_gforce(delta: float) -> void:
	if ac == null or not is_instance_valid(ac) or not ac.alive:
		_blackout = move_toward(_blackout, 0.0, delta)
		_redout = move_toward(_redout, 0.0, delta)
		return
	var g := ac.g_load
	# Sustained high G drains blood from the head: tunnel vision then blackout.
	if g > 7.0:
		_g_timer += delta * (g - 7.0)
	else:
		_g_timer = maxf(_g_timer - delta * 1.5, 0.0)
	_blackout = clampf(_g_timer / 6.0, 0.0, 1.0)
	_redout = clampf(_redout + (delta * 0.6 if g < -2.5 else -delta), 0.0, 0.8)


# ===================================================================== drawing helpers

func _txt(pos: Vector2, s: String, size := 16, col := GREEN, align := HORIZONTAL_ALIGNMENT_LEFT, width := -1.0) -> void:
	draw_string(_font, pos + Vector2(1, 1), s, align, width, size, SHADOW)
	draw_string(_font, pos, s, align, width, size, col)


func _line(a: Vector2, b: Vector2, col := GREEN, w := 2.0) -> void:
	draw_line(a, b, col, w, true)


func _cam() -> Camera3D:
	return get_viewport().get_camera_3d()


func _proj(world: Vector3) -> Variant:
	var cam := _cam()
	if cam == null or cam.is_position_behind(world):
		return null
	return cam.unproject_position(world)


# ===================================================================== main draw

func _draw() -> void:
	var size := get_viewport_rect().size
	if _redout > 0.01:
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.5, 0.0, 0.0, _redout * 0.7))
	if ac != null and is_instance_valid(ac) and show_hud:
		_draw_flight(size)
	if session != null and session.has_method("hud_info"):
		_draw_session(size, session.hud_info())
	_draw_messages(size)
	_draw_blackout(size)
	if _big_time > 0.0:
		var a := clampf(_big_time, 0.0, 1.0)
		_txt(Vector2(0, size.y * 0.32), _big_text, 46, Color(1, 1, 1, a), HORIZONTAL_ALIGNMENT_CENTER, size.x)
		if _big_sub != "":
			_txt(Vector2(0, size.y * 0.32 + 42), _big_sub, 22, Color(0.9, 0.95, 1, a), HORIZONTAL_ALIGNMENT_CENTER, size.x)


func _draw_blackout(size: Vector2) -> void:
	if _blackout <= 0.01:
		return
	var c := size * 0.5
	var r0 := size.length() * (0.65 - _blackout * 0.5)
	for i in 14:
		var r := r0 + i * 40.0
		draw_arc(c, r, 0, TAU, 64, Color(0, 0, 0, clampf(_blackout * 0.25 + i * 0.07 * _blackout, 0, 1)), 44.0)
	if _blackout > 0.85:
		draw_rect(Rect2(Vector2.ZERO, size), Color(0, 0, 0, (_blackout - 0.85) / 0.15))


func _draw_flight(size: Vector2) -> void:
	var cam := _cam()
	if cam == null:
		return
	var fighter := ac.type_id == "f16"
	var col := GREEN if fighter else WHITE
	if not ac.alive:
		_txt(Vector2(0, size.y * 0.5), "AIRCRAFT DESTROYED", 40, RED, HORIZONTAL_ALIGNMENT_CENTER, size.x)
		_txt(Vector2(0, size.y * 0.5 + 34), "Press R to try again", 20, WHITE, HORIZONTAL_ALIGNMENT_CENTER, size.x)
		return
	var pos := ac.get_global_transform_interpolated().origin
	var fwd := -ac.get_global_transform_interpolated().basis.z
	var far := 3000.0
	var bore = _proj(pos + fwd * far)
	var center := size * 0.5
	var hud_r := size.y * 0.36
	var hud_c: Vector2 = bore if bore != null else center
	# Pitch ladder: conformal lines every 5 degrees.
	var hdg_dir := Vector3(fwd.x, 0, fwd.z)
	if hdg_dir.length_squared() < 1e-4:
		hdg_dir = Vector3(-ac.global_transform.basis.y.x, 0, -ac.global_transform.basis.y.z)
	hdg_dir = hdg_dir.normalized()
	var right := hdg_dir.cross(Vector3.UP).normalized()
	for deg in range(-90, 91, 5):
		var th := deg_to_rad(deg)
		var d := hdg_dir * cos(th) + Vector3.UP * sin(th)
		var p0 = _proj(pos + d * far)
		if p0 == null:
			continue
		if (p0 as Vector2).distance_to(hud_c) > hud_r:
			continue
		var p1 = _proj(pos + d * far + right * far * 0.06)
		if p1 == null:
			continue
		var dir: Vector2 = ((p1 as Vector2) - (p0 as Vector2)).normalized()
		var half := 160.0 if deg == 0 else 70.0
		var gap := 0.0 if deg == 0 else 28.0
		var a: Vector2 = p0 - dir * half
		var b: Vector2 = p0 + dir * half
		var lc := col if deg >= 0 else Color(col, 0.8)
		if deg == 0:
			_line(a, b, lc, 2.0)
		elif deg > 0:
			_line(a, p0 - dir * gap, lc, 2.0)
			_line(p0 + dir * gap, b, lc, 2.0)
			var nrm := Vector2(dir.y, -dir.x)
			_line(a, a - nrm * 8.0, lc, 2.0)
			_line(b, b - nrm * 8.0, lc, 2.0)
		else:
			# dashed for negative pitch
			for k in 4:
				var s0 := a.lerp(p0 - dir * gap, k / 4.0)
				var s1 := a.lerp(p0 - dir * gap, (k + 0.55) / 4.0)
				_line(s0, s1, lc, 2.0)
				var e0: Vector2 = (p0 + dir * gap).lerp(b, k / 4.0)
				var e1: Vector2 = (p0 + dir * gap).lerp(b, (k + 0.55) / 4.0)
				_line(e0, e1, lc, 2.0)
		if deg != 0 and deg % 10 == 0:
			_txt(b + dir * 6.0 + Vector2(0, 6), str(absi(deg)), 14, lc)
	# Boresight / gun cross
	if bore != null:
		var bp: Vector2 = bore
		_line(bp + Vector2(-14, 0), bp + Vector2(-5, 0), col)
		_line(bp + Vector2(5, 0), bp + Vector2(14, 0), col)
		_line(bp + Vector2(0, -12), bp + Vector2(0, -4), col)
	# Flight path marker
	if ac.airspeed > 5.0:
		var fpm = _proj(pos + ac.linear_velocity.normalized() * far)
		if fpm != null:
			var fp: Vector2 = fpm
			draw_arc(fp, 8.0, 0, TAU, 20, col, 2.0, true)
			_line(fp + Vector2(-8, 0), fp + Vector2(-20, 0), col)
			_line(fp + Vector2(8, 0), fp + Vector2(20, 0), col)
			_line(fp + Vector2(0, -8), fp + Vector2(0, -16), col)
	_draw_tapes(size, col)
	_draw_heading(size, col)
	_draw_systems(size, col)
	if fighter:
		_draw_targeting(size, col, bore)
	_draw_damage(Vector2(size.x - 130, size.y - 170))
	_draw_radar(Vector2(size.x - 120, 130))
	_draw_warnings(size)
	if not fighter:
		_draw_pfd(Vector2(24, size.y - 250))


func _draw_tapes(size: Vector2, col: Color) -> void:
	var cy := size.y * 0.5
	var lx := size.x * 0.5 - 330.0
	var rx := size.x * 0.5 + 330.0
	var kts := ac.ias * 1.94384
	var ft := ac.altitude * 3.28084
	# Speed tape
	for i in range(-6, 7):
		var v := int(round(kts / 10.0)) * 10 + i * 10
		if v < 0:
			continue
		var y := cy - (v - kts) * 4.0
		if absf(y - cy) > 130:
			continue
		_line(Vector2(lx + 40, y), Vector2(lx + (52 if v % 50 == 0 else 46), y), col, 1.5)
		if v % 50 == 0:
			_txt(Vector2(lx - 20, y + 6), str(v), 14, col)
	draw_rect(Rect2(lx - 30, cy - 16, 66, 30), Color(0, 0, 0, 0.35))
	draw_rect(Rect2(lx - 30, cy - 16, 66, 30), col, false, 2.0)
	_txt(Vector2(lx - 26, cy + 7), "%d" % int(kts), 20, col)
	_txt(Vector2(lx - 30, cy - 34), "G %.1f" % ac.g_load, 16, RED if ac.over_g else col)
	_txt(Vector2(lx - 30, cy + 40), "M %.2f" % ac.mach, 16, col)
	_txt(Vector2(lx - 30, cy + 60), "α %.1f" % rad_to_deg(ac.aoa), 16, AMBER if ac.stalled else col)
	_txt(Vector2(lx - 30, cy + 80), "GS %d" % int(Vector2(ac.linear_velocity.x, ac.linear_velocity.z).length() * 1.94384), 14, col)
	# Altitude tape
	for i in range(-6, 7):
		var a := int(round(ft / 100.0)) * 100 + i * 100
		var y := cy - (a - ft) * 0.4
		if absf(y - cy) > 130:
			continue
		_line(Vector2(rx - 52, y), Vector2(rx - (40 if a % 500 == 0 else 46), y), col, 1.5)
		if a % 500 == 0:
			_txt(Vector2(rx - 34, y + 6), str(a), 14, col)
	draw_rect(Rect2(rx - 36, cy - 16, 84, 30), Color(0, 0, 0, 0.35))
	draw_rect(Rect2(rx - 36, cy - 16, 84, 30), col, false, 2.0)
	_txt(Vector2(rx - 32, cy + 7), "%d" % int(ft), 20, col)
	var vs := ac.vertical_speed * 196.85
	_txt(Vector2(rx - 36, cy - 34), "VS %+d" % int(vs), 14, col)
	var radar_ft := ac.agl * 3.28084
	if radar_ft < 2500.0:
		_txt(Vector2(rx - 36, cy + 40), "R %04d" % maxi(int(radar_ft), 0), 16, AMBER if radar_ft < 200 else col)


func _draw_heading(size: Vector2, col: Color) -> void:
	var cx := size.x * 0.5
	var y := 46.0
	var hdg := ac.heading_deg()
	for i in range(-25, 26):
		var h := int(round(hdg)) + i
		var x := cx + (h - hdg) * 9.0
		var hm := posmod(h, 360)
		if hm % 5 != 0:
			continue
		_line(Vector2(x, y), Vector2(x, y + (12 if hm % 10 == 0 else 6)), col, 1.5)
		if hm % 10 == 0:
			var label := str(hm / 10).pad_zeros(2)
			match hm:
				0: label = "N"
				90: label = "E"
				180: label = "S"
				270: label = "W"
			_txt(Vector2(x - 9, y - 4), label, 14, col)
	_line(Vector2(cx, y + 16), Vector2(cx - 7, y + 26), col)
	_line(Vector2(cx, y + 16), Vector2(cx + 7, y + 26), col)
	_txt(Vector2(cx - 20, y + 44), "%03d" % int(hdg), 16, col)


func _draw_systems(size: Vector2, col: Color) -> void:
	var x := 24.0
	var y := size.y - 150.0 if ac.type_id == "f16" else size.y - 290.0
	var thr := ac.throttle
	var thr_txt := "THR %3d%%" % int(minf(thr, 1.0) * 100.0)
	if ac.ab_level > 0.05:
		thr_txt += "  AB"
	_txt(Vector2(x, y), thr_txt, 18, AMBER if ac.ab_level > 0.05 else col)
	for i in ac.engine_rpm.size():
		var e: Dictionary = ac.spec.engines[i]
		var ok := ac.part_frac(e.part)
		var ecol := col if ok > 0.6 else (AMBER if ok > 0.0 else RED)
		var bw := 120.0
		draw_rect(Rect2(x, y + 10 + i * 16, bw, 10), Color(0, 0, 0, 0.4))
		draw_rect(Rect2(x, y + 10 + i * 16, bw * clampf(ac.engine_rpm[i], 0, 1), 10), ecol)
		var lab := "N1 %d%%" % int(ac.engine_rpm[i] * 100.0)
		if ok <= 0.0:
			lab = "ENG FAIL"
		elif ac.fires.has(e.part):
			lab = "ENG FIRE"
		_txt(Vector2(x + bw + 8, y + 20 + i * 16), lab, 13, ecol)
	var yy := y + 18 + ac.engine_rpm.size() * 16 + 12
	var gear_txt := "GEAR DOWN" if ac.gear_pos > 0.99 else ("GEAR UP" if ac.gear_pos < 0.01 else "GEAR TRANSIT")
	var gcol := GREEN if ac.gear_pos > 0.99 else (AMBER if ac.gear_pos > 0.01 else col)
	_txt(Vector2(x, yy), gear_txt, 15, gcol)
	_txt(Vector2(x + 120, yy), "FLAPS %d" % ac.flap_setting, 15, col)
	yy += 20
	if ac.brake > 0.1:
		_txt(Vector2(x, yy), "BRAKES", 15, AMBER)
	if ac.speedbrake:
		_txt(Vector2(x + 80, yy), "SPD BRK", 15, AMBER)
	if ac.fbw_override:
		_txt(Vector2(x + 170, yy), "PROT OFF", 15, RED)
	if pc != null and pc.mouse_aim:
		_txt(Vector2(x, yy + 20), "MOUSE AIM", 14, Color(0.6, 0.85, 1))


func _draw_targeting(size: Vector2, col: Color, bore) -> void:
	var pos := ac.global_position
	# Weapons readout
	var wx := size.x - 250.0
	var wy := size.y - 230.0
	_txt(Vector2(wx, wy), "GUN %d" % ac.gun_ammo, 16, col if ac.gun_ammo > 0 else RED)
	_txt(Vector2(wx, wy + 20), "AIM-9 x%d" % ac.missiles_left, 16, col if ac.missiles_left > 0 else RED)
	_txt(Vector2(wx, wy + 40), "FLR %d" % ac.flares_left, 16, col if ac.flares_left > 0 else RED)
	# Every hostile: small box / edge arrow.
	for a in Aircraft.all:
		if a == ac or not a.alive:
			continue
		var tcol := RED if a.team != ac.team and a.team != 2 else (WHITE if a.team == 2 else Color(0.4, 0.8, 1))
		var sel := pc != null and a == pc.selected_target
		var p = _proj(a.global_position)
		var dist := a.global_position.distance_to(pos)
		if p != null and Rect2(Vector2.ZERO, size).has_point(p):
			var s := 14.0 if not sel else 22.0
			var pp: Vector2 = p
			draw_rect(Rect2(pp - Vector2(s, s), Vector2(s, s) * 2.0), tcol, false, 2.0 if sel else 1.2)
			if sel or dist < 3000.0:
				_txt(pp + Vector2(s + 4, -s + 12), "%.1f" % (dist / 1852.0), 13, tcol)
			if sel and pc.locked:
				var d := 30.0
				_line(pp + Vector2(0, -d), pp + Vector2(d, 0), RED, 2.5)
				_line(pp + Vector2(d, 0), pp + Vector2(0, d), RED, 2.5)
				_line(pp + Vector2(0, d), pp + Vector2(-d, 0), RED, 2.5)
				_line(pp + Vector2(-d, 0), pp + Vector2(0, -d), RED, 2.5)
				_txt(pp + Vector2(-20, -d - 8), "LOCK", 16, RED)
		elif sel or (a.team != ac.team and a.team != 2 and dist < 4000.0):
			_edge_arrow(size, a.global_position, tcol, "%.1f" % (dist / 1852.0))
	# Missile seeker circle
	if bore != null and ac.missiles_left > 0 and pc != null:
		var r := 70.0
		if pc.locked:
			draw_arc(bore, r, 0, TAU, 48, RED, 2.0, true)
		elif pc.lock_progress > 0.0:
			draw_arc(bore, r, -PI * 0.5, -PI * 0.5 + TAU * pc.lock_progress, 48, AMBER, 2.0, true)
		else:
			for k in 12:
				var a0 := TAU * k / 12.0
				draw_arc(bore, r, a0, a0 + TAU / 24.0, 6, Color(col, 0.6), 1.5, true)
	# Gun pipper: where rounds will be at the selected target's range.
	if pc != null and pc.selected_target != null and is_instance_valid(pc.selected_target) and ac.gun_ammo > 0:
		var tg := pc.selected_target
		var dist2 := tg.global_position.distance_to(pos)
		if dist2 < 1800.0:
			var vb := ac.linear_velocity + ac.forward() * 1050.0
			var t := dist2 / vb.length()
			var impact := pos + vb * t + Vector3(0, -0.5 * 9.81 * t * t, 0)
			var lead_pt := tg.global_position + tg.linear_velocity * t
			var ip = _proj(impact)
			var lp = _proj(lead_pt)
			if ip != null:
				var ipv: Vector2 = ip
				draw_arc(ipv, 22.0, 0, TAU, 32, col, 2.0, true)
				draw_circle(ipv, 2.5, col)
				var range_frac := clampf(1.0 - dist2 / 1800.0, 0.0, 1.0)
				draw_arc(ipv, 28.0, -PI * 0.5, -PI * 0.5 + TAU * range_frac, 32, col, 3.0, true)
				if lp != null:
					var lpv: Vector2 = lp
					if lpv.distance_to(ipv) < 24.0:
						_txt(ipv + Vector2(-22, 48), "SHOOT", 16, RED)
	if pc != null and pc.selected_target != null and is_instance_valid(pc.selected_target):
		var tg2 := pc.selected_target
		var d3 := tg2.global_position.distance_to(pos)
		var closure := -(tg2.linear_velocity - ac.linear_velocity).dot((tg2.global_position - pos).normalized())
		_txt(Vector2(wx, wy + 66), "TGT %s" % tg2.callsign, 15, RED)
		_txt(Vector2(wx, wy + 84), "RNG %.1f NM  Vc %d" % [d3 / 1852.0, int(closure * 1.94384)], 14, col)


func _edge_arrow(size: Vector2, world: Vector3, col: Color, label: String) -> void:
	var cam := _cam()
	var local := cam.global_transform.affine_inverse() * world
	var dir := Vector2(local.x, -local.y).normalized()
	var c := size * 0.5
	var r := size.y * 0.42
	var p := c + dir * r
	var n := Vector2(-dir.y, dir.x)
	draw_colored_polygon(PackedVector2Array([p + dir * 14.0, p + n * 9.0, p - n * 9.0]), col)
	_txt(p - dir * 24.0 + Vector2(-12, 5), label, 12, col)


func _draw_damage(origin: Vector2) -> void:
	var o := origin
	draw_rect(Rect2(o - Vector2(60, 70), Vector2(120, 150)), Color(0, 0, 0, 0.3))
	var fighter := ac.type_id == "f16"
	var shapes := {}
	if fighter:
		shapes = {
			"cockpit": [Rect2(o + Vector2(-6, -60), Vector2(12, 24))],
			"fuselage": [Rect2(o + Vector2(-8, -36), Vector2(16, 70))],
			"wing_l": [Rect2(o + Vector2(-50, -6), Vector2(42, 22))],
			"wing_r": [Rect2(o + Vector2(8, -6), Vector2(42, 22))],
			"tail_h": [Rect2(o + Vector2(-28, 38), Vector2(56, 10))],
			"tail_v": [Rect2(o + Vector2(-2, 24), Vector2(4, 30))],
			"engine": [Rect2(o + Vector2(-5, 50), Vector2(10, 14))],
		}
	else:
		shapes = {
			"cockpit": [Rect2(o + Vector2(-6, -64), Vector2(12, 16))],
			"fuselage": [Rect2(o + Vector2(-6, -48), Vector2(12, 106))],
			"wing_l": [Rect2(o + Vector2(-56, -8), Vector2(50, 16))],
			"wing_r": [Rect2(o + Vector2(6, -8), Vector2(50, 16))],
			"engine_l": [Rect2(o + Vector2(-28, -20), Vector2(8, 12))],
			"engine_r": [Rect2(o + Vector2(20, -20), Vector2(8, 12))],
			"tail_h": [Rect2(o + Vector2(-24, 48), Vector2(48, 8))],
			"tail_v": [Rect2(o + Vector2(-2, 40), Vector2(4, 22))],
		}
	for pname in shapes:
		var f := ac.part_frac(pname)
		var attached: bool = ac.parts.has(pname) and ac.parts[pname].attached
		var c := Color(0.3, 0.9, 0.4, 0.8).lerp(Color(1, 0.8, 0.2, 0.85), clampf((1.0 - f) * 2.0, 0, 1))
		if f < 0.5:
			c = Color(1, 0.8, 0.2, 0.85).lerp(Color(1, 0.2, 0.15, 0.9), clampf((0.5 - f) * 2.0, 0, 1))
		if not attached:
			c = Color(0.25, 0.25, 0.25, 0.6)
		if ac.fires.has(pname) and fmod(_t, 0.5) < 0.25:
			c = Color(1, 0.45, 0.1, 1)
		for r in shapes[pname]:
			draw_rect(r, c)
			if not attached:
				_line(r.position, r.end, RED, 1.5)
				_line(Vector2(r.end.x, r.position.y), Vector2(r.position.x, r.end.y), RED, 1.5)
	_txt(o + Vector2(-56, 76), "INTEGRITY %d%%" % int(ac.total_health() * 100.0), 12, WHITE)


func _draw_radar(c: Vector2) -> void:
	var r := 90.0
	var rng := 12000.0
	draw_circle(c, r, Color(0, 0.08, 0.03, 0.45))
	draw_arc(c, r, 0, TAU, 48, Color(GREEN, 0.6), 1.5, true)
	draw_arc(c, r * 0.5, 0, TAU, 48, Color(GREEN, 0.25), 1.0, true)
	_line(c + Vector2(0, -r), c + Vector2(0, r), Color(GREEN, 0.2), 1.0)
	_line(c + Vector2(-r, 0), c + Vector2(r, 0), Color(GREEN, 0.2), 1.0)
	var hdg := deg_to_rad(ac.heading_deg())
	var pos := ac.global_position
	var to_screen := func(world: Vector3) -> Vector2:
		var d := world - pos
		var east := d.x
		var north := -d.z
		var x := east * cos(hdg) - north * sin(hdg)
		var y := east * sin(hdg) + north * cos(hdg)
		var v := Vector2(x, -y) / rng * r
		if v.length() > r:
			v = v.normalized() * r
		return c + v
	for a in Aircraft.all:
		if a == ac or not a.alive:
			continue
		var col := RED if a.team != ac.team and a.team != 2 else (WHITE if a.team == 2 else Color(0.4, 0.8, 1))
		var p: Vector2 = to_screen.call(a.global_position)
		draw_circle(p, 3.5, col)
	for m in Missile.active:
		if is_instance_valid(m):
			draw_circle(to_screen.call(m.global_position), 2.0, AMBER)
	if session != null and session.has_method("hud_info"):
		var info: Dictionary = session.hud_info()
		if info.has("waypoint"):
			var wp: Vector2 = to_screen.call(info.waypoint)
			draw_colored_polygon(PackedVector2Array([wp + Vector2(0, -6), wp + Vector2(6, 0), wp + Vector2(0, 6), wp + Vector2(-6, 0)]), Color(0.5, 0.8, 1))
	draw_colored_polygon(PackedVector2Array([c + Vector2(0, -7), c + Vector2(5, 6), c + Vector2(-5, 6)]), GREEN)
	_txt(c + Vector2(-r, r + 16), "%d NM" % int(rng / 1852.0), 12, Color(GREEN, 0.7))


func _draw_warnings(size: Vector2) -> void:
	var y := size.y * 0.5 + 150.0
	var lines: Array = []
	var flash := fmod(_t, 0.6) < 0.4
	if pc != null and pc.incoming_missile:
		lines.append(["MISSILE", RED])
	if not ac.on_ground and ac.agl < 150.0 and ac.vertical_speed < -20.0 and ac.agl < -ac.vertical_speed * 4.0:
		lines.append(["PULL UP", RED])
	if ac.stalled and not ac.on_ground and ac.airspeed > 10.0:
		lines.append(["STALL", AMBER])
	if ac.over_g:
		lines.append(["OVER-G", RED])
	if ac.ias > float(ac.spec.vne):
		lines.append(["OVERSPEED", RED])
	for e in ac.spec.engines:
		if ac.fires.has(e.part):
			lines.append(["FIRE " + e.part.to_upper().replace("_", " "), RED])
	if ac.gear_pos < 0.5 and not ac.on_ground and ac.agl < 150.0 and ac.ias < float(ac.spec.stall_speed) * 1.6 and ac.vertical_speed < 0.0:
		lines.append(["GEAR", AMBER])
	for l in lines:
		if flash or l[1] == AMBER:
			_txt(Vector2(0, y), l[0], 28, l[1], HORIZONTAL_ALIGNMENT_CENTER, size.x)
		y += 32


func _draw_pfd(o: Vector2) -> void:
	## Airliner primary flight display: attitude ball with speed and altitude.
	var w := 230.0
	var h := 200.0
	var c := o + Vector2(w * 0.5, h * 0.5)
	draw_rect(Rect2(o, Vector2(w, h)), Color(0.02, 0.02, 0.03, 0.85))
	var bank := ac.bank_angle()
	var pitch := rad_to_deg(ac.pitch_angle())
	var px := 4.0 # px per degree
	var horizon_off := pitch * px
	var dir := Vector2(cos(-bank), sin(-bank))
	var nrm := Vector2(-dir.y, dir.x)
	var hc := c + nrm * -horizon_off * -1.0
	hc = c - Vector2(-sin(-bank), cos(-bank)) * horizon_off
	var big := 400.0
	var sky := PackedVector2Array([hc - dir * big, hc + dir * big, hc + dir * big - nrm * big, hc - dir * big - nrm * big])
	var ground := PackedVector2Array([hc - dir * big, hc + dir * big, hc + dir * big + nrm * big, hc - dir * big + nrm * big])
	# Clip roughly by drawing within the box: draw then mask edges.
	draw_colored_polygon(_clip(sky, Rect2(o + Vector2(40, 10), Vector2(w - 80, h - 20))), Color(0.15, 0.45, 0.85))
	draw_colored_polygon(_clip(ground, Rect2(o + Vector2(40, 10), Vector2(w - 80, h - 20))), Color(0.45, 0.3, 0.15))
	for deg in [-20, -10, 10, 20]:
		var lc: Vector2 = hc - nrm * deg * px
		if Rect2(o + Vector2(40, 10), Vector2(w - 80, h - 20)).has_point(lc):
			_line(lc - dir * 18.0, lc + dir * 18.0, WHITE, 1.5)
	_line(c + Vector2(-40, 0), c + Vector2(-12, 0), Color(1, 0.85, 0.1), 4.0)
	_line(c + Vector2(12, 0), c + Vector2(40, 0), Color(1, 0.85, 0.1), 4.0)
	draw_rect(Rect2(c - Vector2(3, 3), Vector2(6, 6)), Color(1, 0.85, 0.1))
	_txt(o + Vector2(4, h * 0.5 + 6), "%d" % int(ac.ias * 1.94384), 16, WHITE)
	_txt(o + Vector2(w - 38, h * 0.5 + 6), "%d" % int(round(ac.altitude * 3.28084 / 10.0) * 10), 14, WHITE)
	_txt(o + Vector2(4, 18), "SPD", 11, Color(0.6, 0.9, 1))
	_txt(o + Vector2(w - 36, 18), "ALT", 11, Color(0.6, 0.9, 1))
	_txt(o + Vector2(w * 0.5 - 30, h - 4), "HDG %03d" % int(ac.heading_deg()), 13, WHITE)


func _clip(poly: PackedVector2Array, r: Rect2) -> PackedVector2Array:
	var box := PackedVector2Array([r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)])
	var res := Geometry2D.intersect_polygons(poly, box)
	return res[0] if not res.is_empty() else PackedVector2Array([Vector2.ZERO, Vector2.ZERO, Vector2.ZERO])


func _draw_session(size: Vector2, info: Dictionary) -> void:
	var x := 24.0
	var y := 34.0
	if info.has("title"):
		_txt(Vector2(x, y), info.title, 22, WHITE)
		y += 26
	for line in info.get("lines", []):
		_txt(Vector2(x, y), line, 16, Color(0.9, 0.95, 1))
		y += 20
	if info.has("waypoint") and ac != null and is_instance_valid(ac) and ac.alive and show_hud:
		var wp: Vector3 = info.waypoint
		var p = _proj(wp)
		var dist := wp.distance_to(ac.global_position)
		var label: String = info.get("waypoint_label", "")
		var col := Color(0.5, 0.85, 1.0)
		if p != null and Rect2(Vector2.ZERO, size).has_point(p):
			var pp: Vector2 = p
			draw_colored_polygon(PackedVector2Array([pp + Vector2(0, -10), pp + Vector2(10, 0), pp + Vector2(0, 10), pp + Vector2(-10, 0)]), Color(col, 0.35))
			draw_polyline(PackedVector2Array([pp + Vector2(0, -12), pp + Vector2(12, 0), pp + Vector2(0, 12), pp + Vector2(-12, 0), pp + Vector2(0, -12)]), col, 2.0)
			_txt(pp + Vector2(16, 5), "%s %.1f km" % [label, dist / 1000.0], 14, col)
		else:
			_edge_arrow(size, wp, col, "%.1f km" % (dist / 1000.0))
	# Trick popups (stacked, centre-right)
	var py := size.y * 0.3
	for p2 in _popup:
		var a := clampf(p2[2], 0.0, 1.0)
		_txt(Vector2(size.x * 0.5 + 200, py), p2[0], 24, Color(p2[1], a))
		py += 30


func _draw_messages(size: Vector2) -> void:
	var y := size.y - 60.0
	for m in _messages:
		var a := clampf(m[2], 0.0, 1.0)
		_txt(Vector2(0, y), m[0], 18, Color(m[1], a), HORIZONTAL_ALIGNMENT_CENTER, size.x)
		y -= 24
