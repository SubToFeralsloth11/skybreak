class_name Tricks
extends RefCounted
## Detects stunts for score: close calls with buildings, threading gaps, flying under the bridge,
## deck runs, inverted/knife-edge flight, rolls, loops, supersonic passes. Chains build a multiplier.

signal trick(name: String, points: int)

var ac: Aircraft
var score := 0
var combo := 1.0
var _combo_t := 0.0
var _scan_t := 0.0
var _near_cd := {}
var _inv_t := 0.0
var _knife_t := 0.0
var _deck_t := 0.0
var _roll_acc := 0.0
var _roll_t := 0.0
var _pitch_acc := 0.0
var _pitch_t := 0.0
var _supersonic_done := false
var _boom_cd := 0.0
var _bridge_side := 0.0
var _awarded_inv := false
var _awarded_knife := false
var _deck_awarded := false
var _high_g_cd := 0.0


func _init(p_ac: Aircraft) -> void:
	ac = p_ac


func _award(name: String, pts: int) -> void:
	var total := int(pts * combo)
	score += total
	trick.emit(name + (" x%.1f" % combo if combo > 1.0 else ""), total)
	combo = minf(combo + 0.5, 5.0)
	_combo_t = 5.0


func tick(dt: float) -> void:
	if ac == null or not is_instance_valid(ac) or not ac.alive:
		return
	_combo_t -= dt
	if _combo_t <= 0.0:
		combo = 1.0
	var world := World.instance
	var pos := ac.global_position
	var speed := ac.airspeed
	var bank := absf(rad_to_deg(ac.bank_angle()))
	var airliner := ac.type_id == "airliner"
	var mult := 3 if airliner else 1
	if ac.on_ground:
		_inv_t = 0.0
		_knife_t = 0.0
		_deck_t = 0.0
		return

	# Buildings: close calls and gaps (20 Hz).
	_scan_t -= dt
	if _scan_t <= 0.0 and world != null and speed > 70.0:
		_scan_t = 0.05
		var half_span := 5.0 if not airliner else 17.0
		var near: Array[AABB] = world.buildings_near(pos, 120.0)
		var sides := {}
		for bb in near:
			var gap := _aabb_distance(bb, pos) - half_span
			if gap < 0.0:
				continue
			var key := bb.position
			if gap < 25.0 and _near_cd.get(key, 0.0) <= 0.0:
				_near_cd[key] = 6.0
				_award("CLOSE CALL", 150 * mult if gap > 10.0 else 300 * mult)
			if gap < 45.0:
				var side := signf((bb.get_center() - pos).dot(ac.global_transform.basis.x))
				sides[side] = true
		if sides.size() == 2 and _near_cd.get("needle", 0.0) <= 0.0:
			_near_cd["needle"] = 3.0
			_award("THREAD THE NEEDLE", 500 * mult)
	for k in _near_cd.keys():
		_near_cd[k] -= dt

	# Under the bridge: cross the gate plane inside its window.
	if world != null and not world.bridge_gate.is_empty():
		var g: Dictionary = world.bridge_gate
		var gb: Basis = g.basis
		var rel: Vector3 = pos - (g.center as Vector3)
		var along := rel.dot(-gb.z)
		var s := signf(along)
		if _bridge_side != 0.0 and s != _bridge_side:
			var sz: Vector2 = g.size
			if absf(rel.dot(gb.x)) < sz.x * 0.5 and absf(rel.dot(gb.y)) < sz.y * 0.5:
				_award("UNDER THE BRIDGE", 1000 * mult)
		_bridge_side = s

	# Deck run: very low and fast.
	if ac.agl < 18.0 and speed > (150.0 if not airliner else 90.0):
		_deck_t += dt
		if _deck_t > 1.5 and not _deck_awarded:
			_deck_awarded = true
			_award("DECK RUN", 300 * mult)
	else:
		_deck_t = 0.0
		_deck_awarded = false

	# Inverted / knife edge.
	if bank > 150.0:
		_inv_t += dt
		if _inv_t > (2.0 if ac.agl < 300.0 else 5.0) and not _awarded_inv:
			_awarded_inv = true
			_award("INVERTED LOW PASS" if ac.agl < 300.0 else "INVERTED", (400 if ac.agl < 300.0 else 150) * mult)
	else:
		_inv_t = 0.0
		_awarded_inv = false
	if bank > 75.0 and bank < 105.0 and ac.agl < 200.0:
		_knife_t += dt
		if _knife_t > 1.5 and not _awarded_knife:
			_awarded_knife = true
			_award("KNIFE EDGE", 400 * mult)
	else:
		_knife_t = 0.0
		_awarded_knife = false

	# Rolls and loops from body rates.
	var w := ac.global_transform.basis.inverse() * ac.angular_velocity
	_roll_acc += -w.z * dt
	_roll_t += dt
	if absf(_roll_acc) >= TAU:
		_award("BARREL ROLL IN AN AIRLINER" if airliner else "AILERON ROLL", 2000 if airliner else 100)
		_roll_acc = 0.0
		_roll_t = 0.0
	if _roll_t > 5.0:
		_roll_acc *= 0.5
		_roll_t = 0.0
	_pitch_acc += w.x * dt
	_pitch_t += dt
	if absf(_pitch_acc) >= TAU * 0.97:
		_award("LOOP" if not airliner else "AIRLINER LOOP", 300 * mult * (3 if airliner else 1))
		_pitch_acc = 0.0
		_pitch_t = 0.0
	if _pitch_t > 25.0:
		_pitch_acc = 0.0
		_pitch_t = 0.0

	_high_g_cd -= dt
	if ac.g_load > 8.5 and _high_g_cd <= 0.0:
		_high_g_cd = 15.0
		_award("9G PULL", 150)

	_boom_cd -= dt
	if ac.mach >= 1.0:
		if not _supersonic_done:
			_supersonic_done = true
			_award("SUPERSONIC", 200)
		if ac.agl < 120.0 and _boom_cd <= 0.0:
			_boom_cd = 10.0
			_award("SONIC BOOM PASS", 800)
			Sfx.play_at("explosion", pos, 0.6)
			CameraRig.add_trauma(0.5)


static func _aabb_distance(bb: AABB, p: Vector3) -> float:
	var q := p.clamp(bb.position, bb.end)
	return q.distance_to(p)
