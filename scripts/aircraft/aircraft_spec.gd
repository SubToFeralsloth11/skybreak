class_name AircraftSpec
extends RefCounted
## Physical data for each flyable type. Body frame: -Z forward, +Y up, +X right, origin = reference point.
## Real-world figures (F-16C Block 50, A320-class twin) rounded; areas in m², forces in N, masses in kg.

const TYPES := ["f16", "airliner", "heli"]


static func get_spec(id: String) -> Dictionary:
	match id:
		"heli":
			return _heli()
		"airliner":
			return _airliner()
		_:
			return _f16()


static func display_name(id: String) -> String:
	return get_spec(id).display_name


static func _surface(name: String, part: String, pos: Vector3, normal: Vector3, area: float, cla: float,
		clmax: float, stall_deg: float, cd0: float, k: float, ctrl: Dictionary, max_defl_deg: float,
		tau: float, incidence_deg := 0.0) -> Dictionary:
	return {
		"name": name, "part": part, "pos": pos, "normal": normal.normalized(), "chord": Vector3(0, 0, -1),
		"area": area, "cla": cla, "clmax": clmax, "stall": deg_to_rad(stall_deg), "cd0": cd0, "k": k,
		"ctrl": ctrl, "max_defl": deg_to_rad(max_defl_deg), "tau": tau, "incidence": deg_to_rad(incidence_deg),
	}


static func _f16() -> Dictionary:
	var k_wing := 1.0 / (PI * 0.78 * 3.2)
	return {
		"id": "f16",
		"display_name": "F-16C Fighting Falcon",
		"role": "Multirole fighter",
		"mass": 11800.0,
		"inertia": Vector3(76000.0, 86000.0, 13500.0), # pitch(X), yaw(Y), roll(Z)
		"com": Vector3(0, 0, 0.78),
		"surfaces": [
			# Wing + LERX, split per side so a lost wing produces real asymmetry. Flaperons: roll + flap.
			_surface("wing_l", "wing_l", Vector3(-2.3, 0.0, 1.2), Vector3(0, 1, 0), 15.0, 3.6, 1.6, 32.0, 0.006, k_wing,
				{"roll": 1.0, "flap": 1.0}, 21.0, 0.32),
			_surface("wing_r", "wing_r", Vector3(2.3, 0.0, 1.2), Vector3(0, 1, 0), 15.0, 3.6, 1.6, 32.0, 0.006, k_wing,
				{"roll": -1.0, "flap": 1.0}, 21.0, 0.32),
			# All-moving horizontal stabilators: pitch + differential roll.
			_surface("hstab_l", "tail_h", Vector3(-2.0, -0.1, 6.2), Vector3(0, 1, 0), 3.0, 3.2, 1.2, 24.0, 0.004, 0.2,
				{"pitch": -1.0, "roll": 0.35}, 25.0, 1.0),
			_surface("hstab_r", "tail_h", Vector3(2.0, -0.1, 6.2), Vector3(0, 1, 0), 3.0, 3.2, 1.2, 24.0, 0.004, 0.2,
				{"pitch": -1.0, "roll": -0.35}, 25.0, 1.0),
			_surface("vtail", "tail_v", Vector3(0, 2.0, 5.6), Vector3(1, 0, 0), 5.1, 3.0, 1.1, 22.0, 0.004, 0.25,
				{"yaw": -1.0}, 30.0, 0.45),
			# Fuselage side area: weathervane + side force in sideslip.
			_surface("body_side", "fuselage", Vector3(0, 0.3, -1.5), Vector3(1, 0, 0), 9.0, 0.8, 0.6, 30.0, 0.0, 0.0,
				{}, 0.0, 0.0),
		],
		"body_cd_area": 0.45, # parasitic CdA of fuselage/stores (m²)
		"wave_drag_area": 1.4, # extra CdA at Mach 1
		"gear_cd_area": 0.6,
		"flap_cd_area": 0.4,
		"brake_cd_area": 1.2, # speed brakes
		"engines": [
			{"part": "engine", "pos": Vector3(0, 0, 7.0), "mil": 76300.0, "ab": 129400.0},
		],
		"spool_time": 3.2,
		"has_afterburner": true,
		"wheels": [
			{"name": "nose", "pos": Vector3(0, -1.0, -2.6), "travel": 0.88, "k": 140000.0, "c": 19000.0, "steer": 1.0, "brake": 0.0, "radius": 0.27},
			{"name": "main_l", "pos": Vector3(-1.2, -1.0, 1.4), "travel": 0.95, "k": 330000.0, "c": 42000.0, "steer": 0.0, "brake": 1.0, "radius": 0.33},
			{"name": "main_r", "pos": Vector3(1.2, -1.0, 1.4), "travel": 0.95, "k": 330000.0, "c": 42000.0, "steer": 0.0, "brake": 1.0, "radius": 0.33},
		],
		"max_steer_deg": 32.0,
		"flap_angle_deg": 20.0,
		"flap_clmax": 0.25,
		"wingtips": [Vector3(-4.9, 0.0, 2.6), Vector3(4.9, 0.0, 2.6)],
		"shapes": [
			{"part": "cockpit", "type": "capsule", "center": Vector3(0, 0.15, -5.6), "radius": 0.7, "height": 4.6},
			{"part": "fuselage", "type": "box", "center": Vector3(0, -0.1, 2.0), "size": Vector3(1.7, 1.9, 10.6)},
			{"part": "wing_l", "type": "box", "center": Vector3(-3.0, 0, 1.4), "size": Vector3(3.6, 0.3, 3.4)},
			{"part": "wing_r", "type": "box", "center": Vector3(3.0, 0, 1.4), "size": Vector3(3.6, 0.3, 3.4)},
			{"part": "tail_h", "type": "box", "center": Vector3(0, -0.15, 6.3), "size": Vector3(5.6, 0.25, 2.0)},
			{"part": "tail_v", "type": "box", "center": Vector3(0, 2.0, 5.3), "size": Vector3(0.3, 2.6, 2.8)},
		],
		"wheel_parts": {"nose": "fuselage", "main_l": "fuselage", "main_r": "fuselage"},
		"parts": {
			"fuselage": {"hp": 260.0, "detach": false},
			"cockpit": {"hp": 90.0, "detach": false},
			"wing_l": {"hp": 120.0, "detach": true, "mass_frac": 0.07},
			"wing_r": {"hp": 120.0, "detach": true, "mass_frac": 0.07},
			"tail_h": {"hp": 90.0, "detach": true, "mass_frac": 0.03},
			"tail_v": {"hp": 90.0, "detach": true, "mass_frac": 0.02},
			"engine": {"hp": 140.0, "detach": false},
		},
		# Fly-by-wire limits (normal / override)
		"fbw": {
			"g_max": 9.0, "g_min": -3.0, "aoa_max_deg": 25.0, "pitch_rate_deg": 28.0, "roll_rate_deg": 240.0,
			"override_g_max": 12.5, "override_aoa_deg": 45.0, "override_pitch_rate_deg": 40.0, "override_roll_rate_deg": 300.0,
			"kp_pitch": 5.0, "ki_pitch": 7.0, "kp_roll": 1.1, "ki_roll": 0.6, "yaw_damper": 1.4,
		},
		"structural_g": 11.0, # positive G that starts bending the wings
		"vne": 820.0, # m/s IAS-ish ceiling (dynamic pressure limit)
		"pilot_head": Vector3(0, 0.98, -3.65),
		"chase_distance": 22.0,
		"gun": {"rate": 100.0, "ammo": 510, "muzzle": Vector3(-0.95, 0.35, -3.6), "speed": 1050.0, "damage": 9.0, "spread": 0.0016},
		"missiles": 6,
		"flares": 60,
		"stall_speed": 62.0,
		"v_rotate": 77.0,
		"cruise_speed": 240.0,
	}

static func _heli() -> Dictionary:
	## Light attack helicopter. Physics live in Aircraft._heli_forces; surfaces only give weathervane.
	return {
		"id": "heli",
		"display_name": "AH-6 Little Bird",
		"role": "Aerobatic helicopter - full 3D collective",
		"heli": {
			"max_thrust_g": 2.6, # rotor thrust at full collective, in weights
			"collective_min": -0.75, # negative pitch: hover inverted
			"pitch_rate_deg": 85.0, "roll_rate_deg": 110.0, "yaw_rate_deg": 70.0,
			"response": 3.5, # how hard the rotor chases the commanded rate (1/s): softer = heavier, smoother
			"drag_area": Vector3(9.0, 15.0, 4.0), # side, vertical (disc), frontal (m²)
		},
		"mass": 1400.0,
		"inertia": Vector3(2600.0, 3200.0, 1300.0),
		"com": Vector3(0, 0, 0.2),
		"surfaces": [
			_surface("vtail", "tail_v", Vector3(0, 0.5, 5.2), Vector3(1, 0, 0), 0.9, 3.0, 1.1, 24.0, 0.01, 0.25,
				{}, 0.0, 0.0),
			_surface("hstab", "tail_v", Vector3(0, 0.1, 4.6), Vector3(0, 1, 0), 0.6, 3.0, 1.1, 24.0, 0.01, 0.25,
				{}, 0.0, 0.0),
		],
		"body_cd_area": 0.0,
		"wave_drag_area": 0.0,
		"gear_cd_area": 0.0,
		"flap_cd_area": 0.0,
		"brake_cd_area": 0.0,
		"engines": [
			{"part": "engine", "pos": Vector3(0, 0.9, 0.8), "mil": 0.0, "ab": 0.0},
		],
		"spool_time": 3.0,
		"has_afterburner": false,
		"wheels": [
			{"name": "skid_fl", "pos": Vector3(-1.0, -0.7, -1.2), "travel": 0.55, "k": 60000.0, "c": 9000.0, "steer": 0.0, "brake": 1.0, "radius": 0.06},
			{"name": "skid_fr", "pos": Vector3(1.0, -0.7, -1.2), "travel": 0.55, "k": 60000.0, "c": 9000.0, "steer": 0.0, "brake": 1.0, "radius": 0.06},
			{"name": "skid_rl", "pos": Vector3(-1.0, -0.7, 1.2), "travel": 0.55, "k": 60000.0, "c": 9000.0, "steer": 0.0, "brake": 1.0, "radius": 0.06},
			{"name": "skid_rr", "pos": Vector3(1.0, -0.7, 1.2), "travel": 0.55, "k": 60000.0, "c": 9000.0, "steer": 0.0, "brake": 1.0, "radius": 0.06},
		],
		"max_steer_deg": 0.0,
		"flap_angle_deg": 0.0,
		"flap_clmax": 0.0,
		"wingtips": [],
		"shapes": [
			{"part": "cockpit", "type": "capsule", "center": Vector3(0, 0.0, -1.0), "radius": 0.75, "height": 2.2},
			{"part": "fuselage", "type": "box", "center": Vector3(0, -0.05, 0.4), "size": Vector3(1.4, 1.3, 2.2)},
			{"part": "tail_v", "type": "box", "center": Vector3(0, 0.25, 3.6), "size": Vector3(0.3, 0.3, 3.6)},
		],
		"wheel_parts": {"skid_fl": "fuselage", "skid_fr": "fuselage", "skid_rl": "fuselage", "skid_rr": "fuselage"},
		"parts": {
			"fuselage": {"hp": 200.0, "detach": false},
			"cockpit": {"hp": 80.0, "detach": false},
			"tail_v": {"hp": 70.0, "detach": true, "mass_frac": 0.05},
			"engine": {"hp": 110.0, "detach": false},
			"rotor": {"hp": 120.0, "detach": false},
		},
		"fbw": {
			"g_max": 6.0, "g_min": -4.0, "aoa_max_deg": 90.0, "pitch_rate_deg": 230.0, "roll_rate_deg": 300.0,
			"override_g_max": 8.0, "override_aoa_deg": 90.0, "override_pitch_rate_deg": 230.0, "override_roll_rate_deg": 300.0,
			"kp_pitch": 1.0, "ki_pitch": 0.0, "kp_roll": 1.0, "ki_roll": 0.0, "yaw_damper": 0.0,
		},
		"structural_g": 9.0,
		"vne": 140.0,
		"pilot_head": Vector3(-0.3, 0.45, -1.3),
		"chase_distance": 14.0,
		"gun": {"rate": 60.0, "ammo": 1200, "muzzle": Vector3(0.9, -0.4, -1.4), "speed": 900.0, "damage": 7.0, "spread": 0.003},
		"missiles": 4,
		"flares": 40,
		"stall_speed": 0.0,
		"v_rotate": 0.0,
		"cruise_speed": 45.0,
	}



static func _airliner() -> Dictionary:
	var k_wing := 1.0 / (PI * 0.82 * 9.5)
	return {
		"id": "airliner",
		"display_name": "Airliner (A320-class twinjet)",
		"role": "Short/medium-haul passenger jet, 150 seats",
		"mass": 64000.0,
		"inertia": Vector3(3.1e6, 4.4e6, 1.55e6),
		"com": Vector3(0, -0.3, 0.55),
		"surfaces": [
			_surface("wing_l", "wing_l", Vector3(-7.6, -0.7, 1.4), Vector3(0, 1, 0), 61.3, 5.4, 1.45, 15.0, 0.005, k_wing,
				{"roll": 1.0, "flap": 1.0}, 22.0, 0.22, 2.0),
			_surface("wing_r", "wing_r", Vector3(7.6, -0.7, 1.4), Vector3(0, 1, 0), 61.3, 5.4, 1.45, 15.0, 0.005, k_wing,
				{"roll": -1.0, "flap": 1.0}, 22.0, 0.22, 2.0),
			_surface("hstab_l", "tail_h", Vector3(-3.4, 1.0, 16.6), Vector3(0, 1, 0), 15.5, 4.2, 1.1, 16.0, 0.004, 0.08,
				{"pitch": -1.0}, 25.0, 0.5),
			_surface("hstab_r", "tail_h", Vector3(3.4, 1.0, 16.6), Vector3(0, 1, 0), 15.5, 4.2, 1.1, 16.0, 0.004, 0.08,
				{"pitch": -1.0}, 25.0, 0.5),
			_surface("vtail", "tail_v", Vector3(0, 5.0, 15.8), Vector3(1, 0, 0), 21.5, 3.4, 1.1, 20.0, 0.004, 0.12,
				{"yaw": -1.0}, 30.0, 0.5),
			_surface("body_side", "fuselage", Vector3(0, 0.0, -4.0), Vector3(1, 0, 0), 40.0, 0.6, 0.5, 30.0, 0.0, 0.0,
				{}, 0.0, 0.0),
		],
		"body_cd_area": 2.2,
		"wave_drag_area": 6.0,
		"gear_cd_area": 3.4,
		"flap_cd_area": 4.5,
		"brake_cd_area": 4.0, # spoilers
		"engines": [
			{"part": "engine_l", "pos": Vector3(-5.75, -2.1, -2.5), "mil": 120000.0, "ab": 120000.0},
			{"part": "engine_r", "pos": Vector3(5.75, -2.1, -2.5), "mil": 120000.0, "ab": 120000.0},
		],
		"spool_time": 6.0,
		"has_afterburner": false,
		"wheels": [
			{"name": "nose", "pos": Vector3(0, -1.6, -12.6), "travel": 2.15, "k": 520000.0, "c": 90000.0, "steer": 1.0, "brake": 0.0, "radius": 0.38},
			{"name": "main_l", "pos": Vector3(-3.8, -1.3, 1.9), "travel": 2.45, "k": 1350000.0, "c": 260000.0, "steer": 0.0, "brake": 1.0, "radius": 0.58},
			{"name": "main_r", "pos": Vector3(3.8, -1.3, 1.9), "travel": 2.45, "k": 1350000.0, "c": 260000.0, "steer": 0.0, "brake": 1.0, "radius": 0.58},
		],
		"max_steer_deg": 60.0,
		"flap_angle_deg": 35.0,
		"flap_clmax": 1.0,
		"wingtips": [Vector3(-17.3, 2.2, 4.8), Vector3(17.3, 2.2, 4.8)],
		"shapes": [
			{"part": "cockpit", "type": "capsule", "center": Vector3(0, -0.2, -15.8), "radius": 1.95, "height": 5.6},
			{"part": "fuselage", "type": "capsule", "center": Vector3(0, 0.3, 3.0), "radius": 2.0, "height": 33.0},
			{"part": "wing_l", "type": "box", "center": Vector3(-9.45, -0.65, 1.45), "size": Vector3(16.0, 0.8, 4.5), "rot_y": 18.7},
			{"part": "wing_r", "type": "box", "center": Vector3(9.45, -0.65, 1.45), "size": Vector3(16.0, 0.8, 4.5), "rot_y": -18.7},
			{"part": "engine_l", "type": "box", "center": Vector3(-5.75, -2.1, -2.6), "size": Vector3(2.2, 2.2, 4.6)},
			{"part": "engine_r", "type": "box", "center": Vector3(5.75, -2.1, -2.6), "size": Vector3(2.2, 2.2, 4.6)},
			{"part": "tail_h", "type": "box", "center": Vector3(0, 1.3, 16.4), "size": Vector3(12.4, 0.4, 3.4)},
			{"part": "tail_v", "type": "box", "center": Vector3(0, 4.8, 15.6), "size": Vector3(0.5, 6.6, 5.0)},
		],
		"wheel_parts": {"nose": "fuselage", "main_l": "wing_l", "main_r": "wing_r"},
		"parts": {
			"fuselage": {"hp": 520.0, "detach": false},
			"cockpit": {"hp": 160.0, "detach": false},
			"wing_l": {"hp": 260.0, "detach": true, "mass_frac": 0.09},
			"wing_r": {"hp": 260.0, "detach": true, "mass_frac": 0.09},
			"tail_h": {"hp": 160.0, "detach": true, "mass_frac": 0.03},
			"tail_v": {"hp": 160.0, "detach": true, "mass_frac": 0.02},
			"engine_l": {"hp": 150.0, "detach": true, "mass_frac": 0.035},
			"engine_r": {"hp": 150.0, "detach": true, "mass_frac": 0.035},
		},
		"fbw": {
			"g_max": 2.5, "g_min": -1.0, "aoa_max_deg": 13.0, "pitch_rate_deg": 6.0, "roll_rate_deg": 18.0,
			"override_g_max": 6.0, "override_aoa_deg": 25.0, "override_pitch_rate_deg": 14.0, "override_roll_rate_deg": 45.0,
			"kp_pitch": 5.5, "ki_pitch": 6.0, "kp_roll": 3.2, "ki_roll": 1.6, "yaw_damper": 3.0,
		},
		"structural_g": 3.9,
		"vne": 210.0,
		"pilot_head": Vector3(-0.55, 0.6, -15.05),
		"chase_distance": 62.0,
		"gun": {},
		"missiles": 0,
		"flares": 0,
		"stall_speed": 58.0,
		"v_rotate": 74.0,
		"cruise_speed": 215.0,
	}
