class_name Aircraft
extends RigidBody3D
## Six-degree-of-freedom aircraft: per-surface aerodynamics (lift/drag with stall, flaps, control
## deflections), spooling engines with afterburner, fly-by-wire rate controller with G/AoA limits,
## sprung landing gear with tyre friction and brakes, part-based damage with detachable wings/tails/engines.

signal destroyed(aircraft: Aircraft)
signal part_lost(aircraft: Aircraft, part: String)
signal touchdown(aircraft: Aircraft, vertical_speed: float)
signal damaged(aircraft: Aircraft, attacker: Node)

const G := 9.81
const AB_THRESHOLD := 1.0

static var all: Array[Aircraft] = []
static var wind := Vector3.ZERO # m/s, air mass movement (set by modes)

# ---- identity
var spec: Dictionary
var type_id := "f16"
var team := 0 # 0 player side, 1 hostile, 2 civilian
var is_player := false
var callsign := ""

# ---- pilot inputs (written by PlayerController / AIPilot)
var input_pitch := 0.0 # +1 = nose up
var input_roll := 0.0 # +1 = roll right
var input_yaw := 0.0 # +1 = nose right / steer right
var throttle := 0.0 # 0..1 military, up to 1.1 = full afterburner
var brake := 0.0
var speedbrake := false
var flap_setting := 0 # 0..3
var gear_down := true
var fire_gun := false
var fbw_override := false
var collective := 0.0 # helicopters: -1..1 blade pitch, from throttle
var heli_drive := 0.0 # helicopters: -1..1 arrow-key forward/back assist

# ---- state (read by HUD, AI, modes)
var alive := true
var crashed := false
var on_ground := false
var airspeed := 0.0
var ias := 0.0 # indicated airspeed m/s (density corrected)
var mach := 0.0
var aoa := 0.0 # rad
var beta := 0.0
var g_load := 1.0
var altitude := 0.0
var agl := 0.0
var vertical_speed := 0.0
var engine_rpm: Array[float] = []
var ab_level := 0.0
var flap_pos := 0.0
var gear_pos := 1.0 # 1 = down & locked
var stalled := false
var over_g := false
var elevator := 0.0
var aileron := 0.0
var rudder := 0.0
var wheels_in_contact := 0
var last_attacker: Node = null
var kill_credit: Node = null

# ---- damage
var parts := {} # name -> {hp, max, attached, detach, mass_frac, node, center}
var scorch := 0.0
var fires := {} # part -> Node3D effect
var smokes := {} # part -> GPUParticles3D

# ---- weapons
var gun_ammo := 0
var missiles_left := 0
var flares_left := 0
var _gun_accum := 0.0
var _gun_cooldown_heat := 0.0
var flare_cooldown := 0.0

# ---- internals
var model: Dictionary
var _surfaces: Array = []
var _wheels: Array = []
var _shape_parts: Array[String] = []
var _shape_nodes: Array[CollisionShape3D] = []
var _com := Vector3.ZERO
var _base_mass := 1.0
var _int_pitch := 0.0
var _int_roll := 0.0
var _path_hold := false
var _gamma_hold := 0.0
var _v_prev := Vector3.ZERO
var _g_filtered := 1.0
var _contact_dv_prev := 0.0
var _scrape_timer := 0.0
var _exhaust_flames: Array = []
var _vapor: Array[GPUParticles3D] = []
var _snd_rumble: AudioStreamPlayer3D
var _snd_whine: AudioStreamPlayer3D
var _snd_roar: AudioStreamPlayer3D
var _snd_gun: AudioStreamPlayer3D
var _strobe_t := 0.0
var _gear_sound_cooldown := 0.0
var _water_ditched := false
var _crash_freeze_timer := -1.0
var _last_gear_cmd := true
var _wreck_burn := 0.0


## Configure before add_child.
func setup(p_type: String, p_team: int, livery := "default", p_callsign := "") -> void:
	type_id = p_type
	team = p_team
	callsign = p_callsign
	spec = AircraftSpec.get_spec(p_type)
	model = AircraftModel.build(p_type, livery)
	add_child(model.root)
	_com = spec.com
	_base_mass = spec.mass
	mass = spec.mass
	inertia = spec.inertia
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = _com
	linear_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	angular_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	linear_damp = 0.0
	angular_damp = 0.0
	can_sleep = false
	continuous_cd = true
	contact_monitor = true
	max_contacts_reported = 8
	collision_layer = 2
	collision_mask = 1 | 2
	custom_integrator = false
	var pm := PhysicsMaterial.new()
	pm.friction = 0.45
	pm.bounce = 0.0
	physics_material_override = pm

	for s in spec.surfaces:
		var sd: Dictionary = s.duplicate()
		sd["active"] = true
		_surfaces.append(sd)
	for w in spec.wheels:
		var wd: Dictionary = w.duplicate()
		wd["comp"] = 0.0
		wd["contact"] = false
		wd["part"] = spec.wheel_parts.get(w.name, "fuselage")
		wd["broken"] = false
		_wheels.append(wd)
	for e in spec.engines:
		engine_rpm.append(0.0)

	# Parts with their visual node and centroid (for debris + hit location).
	for pname in spec.parts:
		var pd: Dictionary = spec.parts[pname]
		var node: Node3D = model.parts.get(pname)
		parts[pname] = {
			"hp": pd.hp, "max": pd.hp, "attached": true, "detach": pd.detach,
			"mass_frac": pd.get("mass_frac", 0.0), "node": node,
			"center": _node_center(node) if node != null else Vector3.ZERO,
		}
	# Collision shapes, one per entry, mapped to parts.
	for sh in spec.shapes:
		var cs := CollisionShape3D.new()
		if sh.type == "box":
			var b := BoxShape3D.new()
			b.size = sh.size
			cs.shape = b
		else:
			var c := CapsuleShape3D.new()
			c.radius = sh.radius
			c.height = sh.height
			cs.shape = c
			cs.rotation.x = PI * 0.5
		cs.position = sh.center
		if sh.has("rot_y"):
			cs.rotation.y = deg_to_rad(sh.rot_y)
		add_child(cs)
		_shape_nodes.append(cs)
		_shape_parts.append(sh.part)

	gun_ammo = spec.gun.get("ammo", 0)
	missiles_left = spec.missiles
	flares_left = spec.flares
	_setup_exhaust()
	_setup_vapor()
	model.interior.visible = false


func _node_center(node: Node3D) -> Vector3:
	var aabb := AABB()
	var first := true
	for mi in node.find_children("*", "MeshInstance3D", true, false):
		var m := mi as MeshInstance3D
		var box := _xform_to(m, model.root) * m.get_aabb()
		if first:
			aabb = box
			first = false
		else:
			aabb = aabb.merge(box)
	return aabb.get_center()


## Transform of `n` relative to `ancestor` (meshes are authored in body space under the model root).
func _xform_to(n: Node3D, ancestor: Node) -> Transform3D:
	var t := Transform3D.IDENTITY
	var c: Node = n
	while c != null and c != ancestor:
		if c is Node3D:
			t = (c as Node3D).transform * t
		c = c.get_parent()
	return t


func _enter_tree() -> void:
	all.append(self)


func _exit_tree() -> void:
	all.erase(self)


func _ready() -> void:
	_snd_rumble = Sfx.loop_player("jet_rumble", self, 60.0 if type_id == "airliner" else 45.0)
	_snd_whine = Sfx.loop_player("jet_whine", self, 30.0)
	_snd_roar = Sfx.loop_player("roar", self, 60.0)
	_snd_gun = Sfx.loop_player("gun", self, 40.0)
	_snd_gun.stop()


# =====================================================================  helpers

func forward() -> Vector3:
	return -global_transform.basis.z


func up() -> Vector3:
	return global_transform.basis.y


func part_ok(p: String) -> bool:
	return parts.has(p) and parts[p].attached and parts[p].hp > 0.0


func part_frac(p: String) -> float:
	if not parts.has(p) or not parts[p].attached:
		return 0.0
	return clampf(parts[p].hp / parts[p].max, 0.0, 1.0)


func engines_alive() -> int:
	var n := 0
	for e in spec.engines:
		if part_ok(e.part):
			n += 1
	return n


func bank_angle() -> float:
	var b := global_transform.basis
	return atan2(-b.x.y, b.y.y) # positive = right wing down


func pitch_angle() -> float:
	return asin(clampf(forward().y, -1.0, 1.0))


func heading_deg() -> float:
	var f := forward()
	return fposmod(rad_to_deg(atan2(f.x, -f.z)), 360.0)


func ground_height_below() -> float:
	if World.instance != null:
		return World.instance.surface_height_at(global_position.x, global_position.z)
	return 0.0


func rest_height() -> float:
	## Height of the body origin above the ground when resting on the gear.
	var h := 0.0
	for w in spec.wheels:
		h = maxf(h, -(float(w.pos.y) - float(w.travel) * 0.84))
	return h


func place_on_ground(xform: Transform3D) -> void:
	var t := xform
	t.origin.y += rest_height()
	global_transform = t
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	gear_down = true
	gear_pos = 1.0
	throttle = 0.0
	for i in engine_rpm.size():
		engine_rpm[i] = 0.25
	_v_prev = Vector3.ZERO


func place_in_air(xform: Transform3D, speed: float) -> void:
	global_transform = xform
	linear_velocity = -xform.basis.z * speed
	angular_velocity = Vector3.ZERO
	_path_hold = false
	_int_pitch = 0.0
	_int_roll = 0.0
	gear_down = false
	gear_pos = 0.0
	throttle = 0.75 if type_id == "airliner" else 0.8
	for i in engine_rpm.size():
		engine_rpm[i] = throttle
	if spec.has("heli"):
		throttle = _heli_hover_throttle()
		engine_rpm[0] = 1.0
		gear_down = true
		gear_pos = 1.0
	_v_prev = linear_velocity
	_apply_gear_visual()


# =====================================================================  physics

func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	var dt := state.step
	var xf := state.transform
	var b := xf.basis
	var bt := b.transposed()
	var v := state.linear_velocity
	var va := v - wind # air-relative velocity
	var w := state.angular_velocity
	var com_off := b * _com

	altitude = xf.origin.y
	var rho := 1.225 * exp(-maxf(altitude, 0.0) / 8500.0)
	var a_sound := 340.3 - 0.0041 * clampf(altitude, 0.0, 11000.0)
	airspeed = va.length()
	mach = airspeed / a_sound
	ias = airspeed * sqrt(rho / 1.225)
	vertical_speed = v.y
	var lv := bt * va
	aoa = atan2(-lv.y, -lv.z) if airspeed > 2.0 else 0.0
	beta = atan2(lv.x, -lv.z) if airspeed > 2.0 else 0.0
	var qdyn := 0.5 * rho * airspeed * airspeed

	# Load factor from measured acceleration (what the pilot feels).
	var accel := (v - _v_prev) / maxf(dt, 1e-4)
	_v_prev = v
	var specific := accel + Vector3(0, G, 0)
	var n_now := specific.dot(b.y) / G
	_g_filtered = lerpf(_g_filtered, n_now, clampf(dt * 12.0, 0.0, 1.0))
	g_load = _g_filtered

	var wl := bt * w
	var q_rate := wl.x
	var p_rate := -wl.z
	var r_rate := -wl.y

	if spec.has("heli"):
		_heli_forces(state, dt, b, bt, va, w, rho, com_off)
		_gear_forces(state, dt, b, v, w, com_off)
		over_g = false
		_process_contacts(state, dt)
		_post_forces(state, dt, xf, v)
		return

	# ---------------- actuators
	var gear_target := 1.0 if gear_down else 0.0
	gear_pos = move_toward(gear_pos, gear_target, dt / (6.0 if type_id == "airliner" else 4.0))
	var flap_target := float(flap_setting) / 3.0
	flap_pos = move_toward(flap_pos, flap_target, dt / 5.0)

	if alive:
		_fbw(dt, qdyn, q_rate, p_rate, r_rate)
	else:
		elevator = move_toward(elevator, randf_range(-1, 1), dt)
		aileron = move_toward(aileron, randf_range(-1, 1), dt)

	# ---------------- aerodynamics per surface
	var stall_any := false
	for s in _surfaces:
		if not s.active:
			continue
		var pos_local: Vector3 = s.pos
		var r_world := b * (pos_local - _com)
		var vp := va + w.cross(r_world)
		var lvp := bt * vp
		var chord: Vector3 = s.chord
		var nrm: Vector3 = s.normal
		var u_c := lvp.dot(chord)
		var u_n := lvp.dot(nrm)
		var v2 := u_c * u_c + u_n * u_n
		if v2 < 1.0:
			continue
		var ctrl: Dictionary = s.ctrl
		var defl := clampf(ctrl.get("pitch", 0.0) * elevator + ctrl.get("roll", 0.0) * aileron + ctrl.get("yaw", 0.0) * rudder, -1.0, 1.0) * float(s.max_defl)
		var flap_amt := float(ctrl.get("flap", 0.0)) * flap_pos
		defl += flap_amt * deg_to_rad(spec.flap_angle_deg)
		var alpha := atan2(-u_n, u_c) + float(s.incidence)
		var alpha_eff := alpha + defl * float(s.tau)
		var stall_a: float = s.stall + flap_amt * deg_to_rad(-2.0)
		var clmax: float = s.clmax + flap_amt * spec.flap_clmax
		var cl_lin := clampf(float(s.cla) * alpha_eff, -clmax, clmax)
		var cl_plate := 1.05 * sin(2.0 * alpha_eff)
		var blend := smoothstep(stall_a, stall_a + deg_to_rad(10.0), absf(alpha_eff))
		if blend > 0.3 and s.part.begins_with("wing"):
			stall_any = true
		var cl := lerpf(cl_lin, cl_plate, blend)
		# Mach: lift slope rises then falls transonic; just soften lift above M1.3
		cl *= 1.0 - 0.25 * smoothstep(1.1, 2.0, mach)
		var cd: float = s.cd0 + (1.0 - blend) * float(s.k) * cl_lin * cl_lin + blend * 1.25 * pow(sin(alpha_eff), 2.0) + absf(defl) * 0.05
		var eff := lerpf(0.55, 1.0, part_frac(s.part))
		var q_s := 0.5 * rho * v2 * float(s.area) * eff
		var vel_dir := (chord * u_c + nrm * u_n).normalized()
		var lift_dir := (nrm * u_c - chord * u_n).normalized()
		var f_body := (lift_dir * cl - vel_dir * cd) * q_s
		state.apply_force(b * f_body, b * pos_local)
	stalled = stall_any

	# ---------------- parasitic + wave drag
	if airspeed > 0.5:
		var cda: float = spec.body_cd_area + spec.gear_cd_area * gear_pos + spec.flap_cd_area * flap_pos
		cda += spec.brake_cd_area * (1.0 if speedbrake else 0.0)
		cda += spec.wave_drag_area * smoothstep(0.84, 1.02, mach) * (1.0 - 0.4 * smoothstep(1.2, 2.0, mach))
		cda += (1.0 - part_frac("fuselage")) * spec.body_cd_area * 0.8 + scorch * 0.2
		for p in ["wing_l", "wing_r", "tail_h", "tail_v"]:
			if parts.has(p) and not parts[p].attached:
				cda += spec.body_cd_area * 0.3
		state.apply_force(-va.normalized() * qdyn * cda, com_off)

	# ---------------- engines
	var dens := pow(rho / 1.225, 0.75)
	var ram := 1.0 + 0.3 * minf(mach, 2.0)
	var spool_t: float = spec.spool_time
	var want_ab: bool = spec.has_afterburner and throttle > AB_THRESHOLD + 0.001 and alive
	ab_level = move_toward(ab_level, (throttle - AB_THRESHOLD) / 0.1 if want_ab else 0.0, dt * 2.5)
	for i in spec.engines.size():
		var e: Dictionary = spec.engines[i]
		var health := part_frac(e.part)
		var running := health > 0.0 and alive
		var target_rpm := clampf(throttle, 0.0, 1.0) if running else 0.0
		# Jet spool: slow from idle, faster near the top.
		var rate := (0.6 + engine_rpm[i]) / spool_t
		engine_rpm[i] = move_toward(engine_rpm[i], target_rpm, dt * rate)
		if not running:
			continue
		var health_k := 1.0 if health > 0.6 else lerpf(0.35, 1.0, health / 0.6)
		var thrust: float = (0.04 + 0.96 * engine_rpm[i]) * float(e.mil) * dens * (1.0 + 0.12 * minf(mach, 1.0))
		thrust += ab_level * (float(e.ab) - float(e.mil)) * dens * ram
		thrust *= health_k
		state.apply_force(-b.z * thrust, b * (e.pos as Vector3))

	# ---------------- landing gear
	_gear_forces(state, dt, b, v, w, com_off)

	# ---------------- damage from structure
	over_g = g_load > spec.structural_g or g_load < -spec.structural_g * 0.5
	if alive and over_g:
		var excess: float = (absf(g_load) - float(spec.structural_g)) * dt * 22.0
		_damage_part("wing_l", excess * randf_range(0.6, 1.4), null)
		_damage_part("wing_r", excess * randf_range(0.6, 1.4), null)
	var vne: float = spec.vne
	if alive and ias > vne:
		var flutter := (ias - vne) * dt * 2.5
		_damage_part(["wing_l", "wing_r", "tail_h", "tail_v"].pick_random(), flutter, null)

	# ---------------- contacts (crashes, scrapes, mid-airs)
	_process_contacts(state, dt)

	_post_forces(state, dt, xf, v)


func _post_forces(state: PhysicsDirectBodyState3D, dt: float, xf: Transform3D, v: Vector3) -> void:
	# ---------------- water
	if World.instance != null and World.instance.is_over_water(xf.origin.x, xf.origin.z) and xf.origin.y < 1.0:
		_water(state, dt, v)

	# ---------------- ground clearance / tunnelling guard
	if World.instance != null and alive:
		var gh := World.instance.surface_height_at(xf.origin.x, xf.origin.z)
		agl = xf.origin.y - gh - rest_height() * 0.9
		if xf.origin.y < gh - 2.0 and not World.instance.is_over_water(xf.origin.x, xf.origin.z):
			call_deferred("crash", "terrain")
	if _crash_freeze_timer > 0.0:
		_crash_freeze_timer -= dt
		if _crash_freeze_timer <= 0.0:
			state.linear_velocity = Vector3.ZERO
			state.angular_velocity = Vector3.ZERO
			set_deferred("freeze", true)


## Throttle setting that hovers out of ground effect at full rotor speed.
func _heli_hover_throttle() -> float:
	var h: Dictionary = spec.heli
	var c_hover := 1.0 / float(h.max_thrust_g)
	var cmin: float = h.collective_min
	return (c_hover - cmin) / (1.0 - cmin)


## Rotorcraft model: rotor thrust along the mast (collective, rpm², ground effect, translational lift,
## inflow), rate-command cyclic/pedals with rotor-speed authority, anisotropic drag, autorotation,
## and a tail-rotor-loss spin. Negative collective lets it hang and fly inverted.
func _heli_forces(state: PhysicsDirectBodyState3D, dt: float, b: Basis, bt: Basis, va: Vector3, w: Vector3, rho: float, com_off: Vector3) -> void:
	var h: Dictionary = spec.heli
	gear_down = true
	gear_pos = 1.0
	brake = 1.0 if on_ground else 0.0
	var lv := bt * va
	var engine_ok := alive and part_ok("engine")
	var rotor_k := lerpf(0.35, 1.0, part_frac("rotor")) if part_ok("rotor") else 0.0
	# Rotor rpm: governor holds 100 %; with a dead engine, upflow through the disc keeps it turning.
	var rpm := engine_rpm[0]
	if engine_ok:
		rpm = move_toward(rpm, 1.0, dt / float(spec.spool_time))
	else:
		var autorot := clampf(-lv.y * signf(collective + 0.001) / 22.0, 0.0, 0.95)
		rpm = move_toward(rpm, autorot, dt * 0.25)
	engine_rpm[0] = rpm
	# Collective follows the throttle with a short hydraulic lag: smooth but immediate.
	var cmin: float = h.collective_min
	var c_target := lerpf(cmin, 1.0, clampf(throttle, 0.0, 1.0)) if alive else 0.0
	collective = lerpf(collective, c_target, clampf(dt * 14.0, 0.0, 1.0))

	# ---------------- rotor thrust
	var ge := 1.0 + 0.22 * clampf(1.0 - agl / 10.0, 0.0, 1.0) * clampf(b.y.y, 0.0, 1.0)
	var v_h := Vector2(lv.x, lv.z).length()
	var etl := 1.0 + 0.15 * smoothstep(7.0, 20.0, v_h)
	# Flow through the disc in the direction of thrust eats blade angle of attack.
	var inflow := clampf(1.0 - lv.y * signf(collective) / 70.0, 0.55, 1.3)
	var thrust := collective * float(h.max_thrust_g) * mass * G * rpm * rpm * ge * etl * inflow * (rho / 1.225) * rotor_k
	state.apply_force(b.y * thrust, com_off)

	# ---------------- cyclic + pedals: rate command, authority scales with rotor speed
	var wl := bt * w
	var want := Vector3(
		input_pitch * deg_to_rad(h.pitch_rate_deg),
		-input_yaw * deg_to_rad(h.yaw_rate_deg),
		-input_roll * deg_to_rad(h.roll_rate_deg))
	var tail_ok := part_ok("tail_v")
	if not tail_ok:
		want.y = 0.0
	var auth := clampf(rpm * rotor_k, 0.0, 1.0) if alive else 0.0
	var acc := (want - wl) * float(h.response) * auth
	if not tail_ok:
		acc.y = (collective * rpm * 7.0 - wl.y * 0.4) * float(alive) # main-rotor torque, nothing to cancel it
	# Light aerodynamic damping always (keeps a dead heli from spinning forever).
	acc -= wl * 0.25
	# Blade flapback: airflow tilts the disc away from the wind, so speed pitches the nose up and
	# sideways drift rolls away; hold cyclic into the speed like a real heli.
	acc.x += -lv.z * 0.010 * auth
	acc.z += lv.x * 0.008 * auth
	# Dissymmetry of lift: advancing blade rolls it slightly at speed.
	acc.z += -lv.z * 0.002 * auth
	var tq := Vector3(acc.x * inertia.x, acc.y * inertia.y, acc.z * inertia.z)
	state.apply_torque(b * tq)
	# Arrow-key drive: level push along the heading, plus lift so speeding up doesn't sink you.
	if absf(heli_drive) > 0.01 and auth > 0.0:
		var flat := Vector3(-b.z.x, 0.0, -b.z.z).normalized()
		state.apply_force((flat * heli_drive * 0.9 + Vector3.UP * absf(heli_drive) * 0.12) * mass * G * auth, com_off)
	aileron = input_roll
	elevator = input_pitch
	rudder = input_yaw

	# ---------------- airframe + disc drag (local axes)
	var area: Vector3 = h.drag_area
	var f_drag := -0.5 * rho * Vector3(lv.x * absf(lv.x) * area.x, lv.y * absf(lv.y) * area.y * (0.4 + 0.6 * rpm), lv.z * absf(lv.z) * area.z)
	state.apply_force(b * f_drag, com_off)

	# Tail fin weathervane.
	for s in _surfaces:
		if not s.active:
			continue
		var pos_local: Vector3 = s.pos
		var nrm: Vector3 = s.normal
		var vp := va + w.cross(b * (pos_local - _com))
		var u_n := (bt * vp).dot(nrm)
		var f := -nrm * u_n * absf(u_n) * 0.5 * rho * float(s.area) * 1.2
		state.apply_force(b * f, b * pos_local)
	stalled = false
	ab_level = 0.0


func _fbw(dt: float, qdyn: float, q: float, p: float, r: float) -> void:
	var f: Dictionary = spec.fbw
	var ov := fbw_override
	var gmax: float = f.override_g_max if ov else f.g_max
	var gmin: float = f.g_min * (1.6 if ov else 1.0)
	var aoa_max := deg_to_rad(f.override_aoa_deg if ov else f.aoa_max_deg)
	var q_max := deg_to_rad(f.override_pitch_rate_deg if ov else f.pitch_rate_deg)
	var p_max := deg_to_rad(f.override_roll_rate_deg if ov else f.roll_rate_deg)
	var v := maxf(airspeed, 25.0)
	var q_ref := 0.5 * 1.225 * pow(float(spec.cruise_speed) * 0.6, 2.0)
	var sched := clampf(q_ref / maxf(qdyn, 50.0), 0.2, 5.0)
	var airborne := not on_ground
	var flying := airborne and airspeed > float(spec.stall_speed) * 0.6

	# --- pitch: rate command; hands-off holds the flight path (and auto-pulls in level turns),
	#     with G and AoA limiters.
	var q_g := gmax * G / v
	var q_cmd: float
	if input_pitch >= 0.0:
		q_cmd = input_pitch * minf(q_max, q_g)
	else:
		q_cmd = input_pitch * minf(q_max, absf(gmin) * G / v + 0.05)
	if flying:
		var bank_now := bank_angle()
		var gamma := asin(clampf(linear_velocity.y / maxf(linear_velocity.length(), 1.0), -1.0, 1.0))
		var level_turn := absf(bank_now) < deg_to_rad(65.0)
		var q_turn := G * sin(bank_now) * tan(bank_now) / v if level_turn else 0.0
		if absf(input_pitch) < 0.04:
			if not _path_hold:
				_path_hold = true
				_gamma_hold = gamma
			if level_turn:
				q_cmd = clampf((_gamma_hold - gamma) * 1.2, -0.12, 0.12) * cos(bank_now) + q_turn
		else:
			_path_hold = false
			q_cmd += q_turn * (1.0 - absf(input_pitch))
		if aoa > aoa_max:
			q_cmd -= (aoa - aoa_max) * 5.0
		if aoa < -deg_to_rad(12.0):
			q_cmd += (-deg_to_rad(12.0) - aoa) * 5.0
		if g_load > gmax:
			q_cmd -= (g_load - gmax) * 0.12
		elif g_load < gmin:
			q_cmd += (gmin - g_load) * 0.12
	var kp: float = f.kp_pitch
	var ki: float = f.ki_pitch
	var err := q_cmd - q
	if flying:
		_int_pitch = clampf(_int_pitch + err * ki * dt * sched, -0.8, 0.8)
	else:
		_int_pitch = move_toward(_int_pitch, 0.0, dt)
	var e_cmd := clampf(err * kp * sched + _int_pitch, -1.0, 1.0)
	if not flying:
		e_cmd = clampf(input_pitch + err * 0.5, -1.0, 1.0)
		# Tail-strike protection while the wheels are on the runway.
		var max_rot := deg_to_rad(10.0 if type_id == "f16" else 9.0)
		if on_ground and pitch_angle() > max_rot - deg_to_rad(2.0):
			e_cmd = minf(e_cmd, (max_rot - pitch_angle()) * 8.0)
	elevator = move_toward(elevator, e_cmd, dt * 6.0)

	# --- roll: rate command, attitude hold
	var bank := bank_angle()
	var p_cmd := input_roll * p_max * clampf(qdyn / (q_ref * 0.3), 0.25, 1.0)
	if type_id == "airliner" and not ov and absf(input_roll) < 0.05 and absf(bank) > deg_to_rad(33.0):
		p_cmd = -signf(bank) * deg_to_rad(5.0) # Airbus-style bank protection
	if type_id == "airliner" and not ov and absf(bank) > deg_to_rad(67.0) and signf(input_roll) == signf(bank):
		p_cmd = 0.0
	var errp := p_cmd - p
	if flying:
		_int_roll = clampf(_int_roll + errp * float(f.ki_roll) * dt * sched, -0.6, 0.6)
	else:
		_int_roll = move_toward(_int_roll, 0.0, dt)
	var a_cmd := clampf(errp * float(f.kp_roll) * sched + _int_roll, -1.0, 1.0)
	if not flying:
		a_cmd = input_roll
	aileron = move_toward(aileron, a_cmd, dt * 8.0)

	# --- yaw: pedals + yaw damper + sideslip suppression
	var r_cmd := input_yaw
	if flying:
		r_cmd = input_yaw * 0.8 - (r - G * sin(bank) / v) * float(f.yaw_damper) * 0.25 * sched + beta * 0.75 * sched
	rudder = move_toward(rudder, clampf(r_cmd, -1.0, 1.0), dt * 5.0)


func _gear_forces(state: PhysicsDirectBodyState3D, dt: float, b: Basis, v: Vector3, w: Vector3, com_off: Vector3) -> void:
	var space := state.get_space_state()
	var origin := state.transform.origin
	var contacts := 0
	var was_on_ground := on_ground
	var max_sink := 0.0
	var steer := deg_to_rad(spec.max_steer_deg) * input_yaw * clampf(1.0 - airspeed / 40.0, 0.15, 1.0)
	for wd in _wheels:
		wd.contact = false
		if gear_pos < 0.999 or wd.broken or not parts.get(wd.part, {"attached": true}).attached:
			wd.comp = 0.0
			continue
		var attach := origin + b * (wd.pos as Vector3)
		var travel: float = wd.travel
		var to := attach - b.y * travel
		var q := PhysicsRayQueryParameters3D.create(attach, to, 1)
		q.exclude = [get_rid()]
		var hit := space.intersect_ray(q)
		var comp := 0.0
		var contact_point := to
		var n := Vector3.UP
		var on_water := false
		if not hit.is_empty():
			comp = travel - attach.distance_to(hit.position)
			contact_point = hit.position
			n = hit.normal
		if comp <= 0.0:
			wd.comp = 0.0
			continue
		var comp_rate: float = (comp - float(wd.comp)) / dt
		wd.comp = comp
		wd.contact = true
		contacts += 1
		var fz: float = maxf(float(wd.k) * comp + float(wd.c) * comp_rate, 0.0)
		# Bottoming out hard = gear collapse.
		if comp > travel * 0.97 and comp_rate > 4.0 and alive:
			_break_wheel(wd)
			continue
		var r_world := contact_point - (origin + com_off)
		var vp := v + w.cross(r_world)
		var fwd := -b.z
		if float(wd.steer) > 0.0:
			fwd = fwd.rotated(b.y, -steer)
		fwd = (fwd - n * fwd.dot(n)).normalized()
		var side := n.cross(fwd).normalized()
		var v_long := vp.dot(fwd)
		var v_lat := vp.dot(side)
		max_sink = maxf(max_sink, -vp.dot(n))
		var m_share := mass / float(_wheels.size())
		var mu := 0.75
		var f_lat := clampf(-v_lat * m_share / dt * 0.25, -mu * fz, mu * fz)
		var roll_res := -clampf(v_long * 2.0, -1.0, 1.0) * 0.012 * fz
		var f_brake := 0.0
		if float(wd.brake) > 0.0 and brake > 0.0:
			f_brake = clampf(-v_long * m_share / dt * 0.25, -0.55 * fz, 0.55 * fz) * brake
		var f := n * fz + side * f_lat + fwd * (roll_res + f_brake)
		state.apply_force(f, contact_point - origin)
		if on_water:
			pass
	wheels_in_contact = contacts
	on_ground = contacts > 0
	if on_ground and not was_on_ground and alive:
		call_deferred("emit_signal", "touchdown", self, -v.y)
		if airspeed > 25.0:
			Sfx.play_at("chirp", origin, 0.7)
		if -v.y > 6.0 and alive:
			# Very hard landing: break the gear.
			for wd in _wheels:
				if wd.contact and randf() < 0.7:
					_break_wheel(wd)


func _break_wheel(wd: Dictionary) -> void:
	wd.broken = true
	wd.contact = false
	Sfx.play_at("tear", global_position, 0.8)
	_damage_part(wd.part, 25.0, null)
	for g in model.gear:
		if g.wheel == wd.name:
			(g.node as Node3D).visible = false


func _process_contacts(state: PhysicsDirectBodyState3D, dt: float) -> void:
	var count := state.get_contact_count()
	if count == 0:
		_scrape_timer = 0.0
		return
	var speed := airspeed
	for i in count:
		var shape_idx := state.get_contact_local_shape(i)
		var part := _shape_parts[shape_idx] if shape_idx >= 0 and shape_idx < _shape_parts.size() else "fuselage"
		var impulse := state.get_contact_impulse(i)
		var dv := impulse.length() / mass
		var other := state.get_contact_collider_object(i)
		var pos := state.get_contact_collider_position(i)
		if other is Aircraft:
			var oa := other as Aircraft
			# Mid-air collision: whatever touched is wrecked.
			if (state.linear_velocity - oa.linear_velocity).length() > 25.0:
				_damage_part(part, 9999.0, oa)
				oa._damage_part("fuselage", 120.0, self)
			continue
		if not alive:
			if speed > 15.0 and _wreck_burn <= 0.0:
				call_deferred("_final_impact", pos)
			continue
		var heavy := dv > 9.0 or (speed > 95.0 and part in ["cockpit", "fuselage"] and dv > 2.0)
		if part in ["wing_l", "wing_r", "tail_h", "tail_v", "engine_l", "engine_r"]:
			if dv > 6.0:
				Fx.sparks(get_parent(), pos, Vector3.UP, 30)
				_damage_part(part, 9999.0, null)
			else:
				_damage_part(part, dv * 12.0 + speed * dt * 0.6, null)
				if speed > 8.0 and randf() < 0.3:
					Fx.sparks(get_parent(), pos, Vector3.UP, 10)
		elif heavy:
			call_deferred("crash", "impact")
			return
		else:
			# Belly scrape / gentle contact.
			_scrape_timer += dt
			_damage_part(part, dv * 15.0 + speed * dt * 1.2, null)
			if fmod(_scrape_timer, 0.08) < dt and speed > 8.0:
				Fx.sparks(get_parent(), pos, Vector3.UP, 10)


func _water(state: PhysicsDirectBodyState3D, dt: float, v: Vector3) -> void:
	var depth := 1.0 - state.transform.origin.y
	if alive and not _water_ditched:
		if airspeed > 70.0 or -v.y > 9.0:
			Fx.impact(get_parent(), global_position, Vector3.UP, true)
			call_deferred("crash", "water")
			return
		_water_ditched = true
		Fx.impact(get_parent(), global_position, Vector3.UP, true)
	# Buoyancy and heavy water drag.
	state.apply_central_force(Vector3.UP * mass * G * clampf(depth, 0.0, 1.6))
	state.apply_central_force(-v * mass * 1.2)
	state.angular_velocity *= 1.0 - minf(dt * 2.0, 1.0)


# =====================================================================  per-frame

func _physics_process(delta: float) -> void:
	if not alive:
		_update_effects(delta)
		return
	_weapons_tick(delta)
	if gear_down != _last_gear_cmd:
		_last_gear_cmd = gear_down
		if is_player:
			Sfx.play("gear", -8.0)
	# Fire spreading: an engine fire slowly eats the wing it hangs on.
	for p in fires:
		if p.begins_with("engine") and parts.has(p):
			_damage_part(p, delta * 1.5, null)
			var wing := "wing_l" if p.ends_with("_l") else ("wing_r" if p.ends_with("_r") else "fuselage")
			_damage_part(wing, delta * 2.2, null)
		elif p == "fuselage":
			_damage_part("fuselage", delta * 2.0, null)
	_update_effects(delta)


func _process(delta: float) -> void:
	_animate_model(delta)
	_update_audio()


func _animate_model(delta: float) -> void:
	for c in model.controls:
		var node = c.node
		if not is_instance_valid(node):
			continue
		if not node.has_meta("base"):
			node.set_meta("base", node.transform)
			node.set_meta("angle", 0.0)
	var angles := {}
	for c in model.controls:
		var node2 = c.node
		if not is_instance_valid(node2):
			continue
		var amt := 0.0
		match c.kind:
			"roll_l": amt = aileron
			"roll_r": amt = -aileron
			"pitch": amt = -elevator
			"pitch_roll_l": amt = aileron
			"pitch_roll_r": amt = -aileron
			"yaw": amt = rudder
			"flap": amt = flap_pos
		var key: int = node2.get_instance_id()
		angles[key] = angles.get(key, 0.0) + amt * float(c.max) * (1.0 if c.kind != "flap" else 1.0)
	for c in model.controls:
		var node3 = c.node
		if not is_instance_valid(node3):
			continue
		var key2: int = node3.get_instance_id()
		if not angles.has(key2):
			continue
		var base: Transform3D = node3.get_meta("base")
		var axis: Vector3 = c.axis
		if axis.x < -0.1:
			axis = -axis
		var t := base
		t.basis = Basis(axis, angles[key2]) * base.basis
		if c.has("slide"):
			t.origin = base.origin + Vector3(0, -0.1, float(c.slide)) * flap_pos
		node3.transform = t
		angles.erase(key2)
	# Landing gear fold + nose-wheel steering + suspension.
	_apply_gear_visual()
	var rotor = model.get("rotor")
	if rotor != null and is_instance_valid(rotor):
		var rrpm: float = engine_rpm[0] if engine_rpm.size() > 0 else 0.0
		(rotor as Node3D).rotate_y(-rrpm * 23.0 * delta)
		var disc = model.get("rotor_disc")
		if disc != null and is_instance_valid(disc):
			((disc as MeshInstance3D).material_override as StandardMaterial3D).albedo_color.a = clampf(rrpm - 0.3, 0.0, 0.7) * 0.35
		var tr = model.get("tail_rotor")
		if tr != null and is_instance_valid(tr) and part_ok("tail_v"):
			(tr as Node3D).rotate_x(rrpm * 70.0 * delta)
	# Nav-light strobes.
	_strobe_t += delta
	for l in model.nav_lights:
		if (l as Node3D).get_meta("strobe", false):
			(l as Node3D).visible = fmod(_strobe_t, 1.2) < 0.08
	# Fire light flicker.
	for p in fires:
		var fx: Node3D = fires[p]
		if is_instance_valid(fx):
			for ch in fx.get_children():
				if ch is OmniLight3D:
					(ch as OmniLight3D).light_energy = 2.0 + randf() * 1.5


func _apply_gear_visual() -> void:
	if model.is_empty():
		return
	for g in model.gear:
		var leg: Node3D = g.node
		var fold := (1.0 - gear_pos) * float(g.fold_angle)
		leg.basis = Basis((g.fold_axis as Vector3), fold)
		leg.visible = gear_pos > 0.02 and not _wheel_broken(g.wheel)
		var steer_node: Node3D = g.steer_node
		var wd := _wheel_by_name(g.wheel)
		var comp: float = wd.get("comp", 0.0) if not wd.is_empty() else 0.0
		steer_node.position = Vector3(0, minf(comp, 0.5) * 0.8, 0)
		if g.wheel == "nose":
			var st := deg_to_rad(spec.max_steer_deg) * input_yaw * clampf(1.0 - airspeed / 40.0, 0.15, 1.0)
			steer_node.rotation.y = -st if on_ground else 0.0


func _wheel_by_name(n: String) -> Dictionary:
	for wd in _wheels:
		if wd.name == n:
			return wd
	return {}


func _wheel_broken(n: String) -> bool:
	var wd := _wheel_by_name(n)
	return not wd.is_empty() and (wd.broken or not parts.get(wd.part, {"attached": true}).attached)


func _setup_exhaust() -> void:
	var shader := preload("res://shaders/afterburner.gdshader")
	for ex in model.exhausts:
		var node: Node3D = ex.node
		var mi := MeshInstance3D.new()
		var cm := CylinderMesh.new()
		var r: float = ex.radius
		var length := 7.0 if spec.has_afterburner else 3.0
		cm.top_radius = r * 0.95
		cm.bottom_radius = r * 0.25
		cm.height = length
		cm.radial_segments = 16
		cm.rings = 6
		mi.mesh = cm
		var mat := ShaderMaterial.new()
		mat.shader = shader
		mat.set_shader_parameter("half_length", length * 0.5)
		mat.set_shader_parameter("intensity", 0.0)
		mat.set_shader_parameter("time_offset", randf() * 10.0)
		mi.material_override = mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.rotation.x = -PI * 0.5 # local +Y -> body +Z
		mi.position = Vector3(0, 0, length * 0.5)
		node.add_child(mi)
		var light := OmniLight3D.new()
		light.light_color = Color(1.0, 0.6, 0.3)
		light.light_energy = 0.0
		light.omni_range = 30.0
		light.position = Vector3(0, 0, 2.0)
		node.add_child(light)
		_exhaust_flames.append({"mat": mat, "light": light, "part": ex.part})


func _setup_vapor() -> void:
	for tip in spec.wingtips:
		var p := Fx.vapor_trail()
		p.position = tip
		p.emitting = false
		add_child(p)
		_vapor.append(p)


func _update_effects(_delta: float) -> void:
	for fl in _exhaust_flames:
		var running := part_frac(fl.part) > 0.0 and alive
		var idx := 0
		for i in spec.engines.size():
			if spec.engines[i].part == fl.part:
				idx = i
		var mil_glow := clampf(engine_rpm[idx] - 0.6, 0.0, 0.4) * 0.25 if spec.has_afterburner else 0.0
		var inten := (ab_level + mil_glow) if running else 0.0
		if not is_instance_valid(fl.light):
			continue
		(fl.mat as ShaderMaterial).set_shader_parameter("intensity", inten)
		(fl.light as OmniLight3D).light_energy = ab_level * 6.0 if running else 0.0
	var vapor_on := alive and (absf(g_load) > (5.5 if type_id == "f16" else 2.2)) and airspeed > 90.0
	for p in _vapor:
		if is_instance_valid(p):
			p.emitting = vapor_on


func _update_audio() -> void:
	if _snd_rumble == null:
		return
	var rpm := 0.0
	for r in engine_rpm:
		rpm = maxf(rpm, r)
	var on := alive and engines_alive() > 0
	_snd_rumble.volume_db = (linear_to_db(0.25 + rpm * 0.9) + 6.0) if on else -80.0
	_snd_rumble.pitch_scale = 0.6 + rpm * 0.6
	_snd_whine.volume_db = (linear_to_db(0.1 + rpm * 0.5) - 2.0) if on else -80.0
	_snd_whine.pitch_scale = 0.5 + rpm * 0.75
	_snd_roar.volume_db = linear_to_db(0.02 + ab_level * 1.2 + (rpm * 0.3 if type_id == "airliner" else 0.0)) + 8.0 if on else -80.0
	_snd_roar.pitch_scale = 0.8 + ab_level * 0.2
	var firing: bool = fire_gun and gun_ammo > 0 and alive and not spec.gun.is_empty()
	if firing and not _snd_gun.playing:
		_snd_gun.play()
	elif not firing and _snd_gun.playing:
		_snd_gun.stop()


# =====================================================================  weapons

func _weapons_tick(delta: float) -> void:
	flare_cooldown = maxf(flare_cooldown - delta, 0.0)
	if spec.gun.is_empty():
		return
	if fire_gun and gun_ammo > 0 and part_ok("fuselage"):
		var gd: Dictionary = spec.gun
		# Simulate every second round with double damage: 50 traced rounds/s.
		_gun_accum += float(gd.rate) * 0.5 * delta
		var muzzle := global_transform * (gd.muzzle as Vector3)
		while _gun_accum >= 1.0 and gun_ammo > 0:
			_gun_accum -= 1.0
			gun_ammo = maxi(gun_ammo - 2, 0)
			var dir := forward()
			var spread: float = gd.spread
			dir = (dir + global_transform.basis.x * randf_range(-spread, spread) + global_transform.basis.y * randf_range(-spread, spread)).normalized()
			if Bullets.instance != null:
				Bullets.instance.fire(muzzle, linear_velocity + dir * float(gd.speed), self, float(gd.damage) * 2.0)
		if randf() < 0.5:
			Fx.flash(get_parent(), muzzle, Color(1.0, 0.75, 0.35), 3.0, 14.0, 0.03)
		if is_player:
			CameraRig.add_trauma(0.06)
	else:
		_gun_accum = 0.0


func fire_missile(target: Node3D) -> Missile:
	if missiles_left <= 0 or not alive:
		return null
	missiles_left -= 1
	var start := global_transform * Vector3(0, -0.8, -2.0)
	# Launch from the first missile still hanging on an attached station.
	for vis in model.missiles:
		var node := vis as Node3D
		if not is_instance_valid(node) or not node.visible:
			continue
		var holder := String(node.get_parent().name)
		if parts.has(holder) and not parts[holder].attached:
			continue
		var mis := node.find_children("*", "MeshInstance3D", true, false)
		if not mis.is_empty():
			start = (mis[0] as MeshInstance3D).global_transform * (mis[0] as MeshInstance3D).get_aabb().get_center()
		node.visible = false
		break
	var m := Missile.new()
	get_parent().add_child(m)
	m.launch(self, start, global_transform.basis, linear_velocity, target)
	return m


func drop_flare() -> void:
	if flares_left <= 0 or flare_cooldown > 0.0 or not alive:
		return
	flare_cooldown = 0.25
	for i in 2:
		flares_left = maxi(flares_left - 1, 0)
		var f := Flare.new()
		get_parent().add_child(f)
		var side := global_transform.basis.x * (1.0 if i == 0 else -1.0)
		f.launch(global_position - global_transform.basis.y * 0.8, linear_velocity * 0.85 + side * 18.0 - global_transform.basis.y * 10.0, self)
	Sfx.play_at("flare", global_position, 0.4)


# =====================================================================  damage

## Bullet/missile hit at a world position. shape_idx from the ray hit (or -1 to choose by distance).
func take_hit(world_pos: Vector3, amount: float, attacker: Node, shape_idx := -1) -> void:
	if not alive:
		return
	var part := "fuselage"
	if shape_idx >= 0 and shape_idx < _shape_parts.size():
		part = _shape_parts[shape_idx]
	else:
		part = _nearest_part(world_pos)
	last_attacker = attacker
	_damage_part(part, amount, attacker)
	# Engines sit inside the airframe: hits nearby hurt them too.
	var local := global_transform.affine_inverse() * world_pos
	for e in spec.engines:
		if local.distance_to(e.pos) < 3.2:
			_damage_part(e.part, amount * 0.8, attacker)
	if randf() < 0.4:
		Fx.sparks(get_parent(), world_pos, (world_pos - global_position).normalized(), 8)
	if randf() < 0.3:
		Sfx.play_at("hit", world_pos, 0.3)
	damaged.emit(self, attacker)
	if is_player:
		CameraRig.add_trauma(0.12)


func blast(center: Vector3, radius: float, max_damage: float, attacker: Node) -> void:
	## Area damage (missile warhead): every part takes damage by its distance to the blast.
	if not alive:
		return
	last_attacker = attacker
	for pname in parts:
		var pd: Dictionary = parts[pname]
		if not pd.attached:
			continue
		var wp := global_transform * (pd.center as Vector3)
		var d := wp.distance_to(center)
		if d < radius:
			_damage_part(pname, max_damage * pow(1.0 - d / radius, 1.3) * randf_range(0.7, 1.3), attacker)
	scorch = minf(scorch + 0.35, 1.0)
	_apply_scorch()
	apply_central_impulse((global_position - center).normalized() * mass * 4.0)
	apply_torque_impulse(Vector3(randf_range(-1, 1), randf_range(-1, 1), randf_range(-1, 1)) * inertia.length() * 0.6)
	damaged.emit(self, attacker)
	if is_player:
		CameraRig.add_trauma(0.7)


func _nearest_part(world_pos: Vector3) -> String:
	var local := global_transform.affine_inverse() * world_pos
	var best := "fuselage"
	var bd := INF
	for pname in parts:
		var pd: Dictionary = parts[pname]
		if not pd.attached:
			continue
		var d := local.distance_squared_to(pd.center)
		if d < bd:
			bd = d
			best = pname
	return best


func _damage_part(pname: String, amount: float, attacker: Node) -> void:
	if not parts.has(pname) or amount <= 0.0:
		return
	var pd: Dictionary = parts[pname]
	if not pd.attached:
		return
	if attacker != null:
		last_attacker = attacker
	var before: float = pd.hp
	pd.hp = maxf(float(pd.hp) - amount, 0.0)
	var frac: float = pd.hp / pd.max
	scorch = maxf(scorch, (1.0 - frac) * 0.4)
	call_deferred("_update_damage_fx", pname, frac)
	if pd.hp <= 0.0 and before > 0.0:
		call_deferred("_part_destroyed", pname)


func _update_damage_fx(pname: String, frac: float) -> void:
	var is_engine := pname.begins_with("engine")
	var anchor := _effect_anchor(pname)
	if frac < 0.65 and not smokes.has(pname) and (is_engine or pname == "fuselage" or pname.begins_with("wing")):
		var sm := Fx.smoke_trail(2.0 if type_id == "f16" else 2.6, 0.45 if frac > 0.4 else 0.85)
		sm.position = anchor
		sm.emitting = true
		add_child(sm)
		smokes[pname] = sm
	if frac < 0.3 and not fires.has(pname) and (is_engine or pname == "fuselage" or pname.begins_with("wing")):
		var fire := Fx.fire_emitter(1.6 if type_id == "f16" else 2.2)
		fire.position = anchor
		add_child(fire)
		fires[pname] = fire
		if smokes.has(pname):
			(smokes[pname] as GPUParticles3D).emitting = false
		if is_player:
			Sfx.play("caution", -6.0)


func _effect_anchor(pname: String) -> Vector3:
	for e in spec.engines:
		if e.part == pname:
			return (e.pos as Vector3) + (Vector3(0, 0, 0.5) if type_id == "f16" else Vector3(0, 0, 1.5))
	if parts.has(pname):
		var c: Vector3 = parts[pname].center
		if pname.begins_with("wing"):
			return Vector3(c.x * 0.55, c.y, c.z)
		return c
	return Vector3.ZERO


func _part_destroyed(pname: String) -> void:
	var pd: Dictionary = parts[pname]
	if pname == "fuselage" or pname == "cockpit":
		explode()
		return
	if pname.begins_with("engine") and not pd.detach:
		# Internal engine: it dies and burns.
		if not fires.has(pname):
			_update_damage_fx(pname, 0.0)
		if is_player:
			Sfx.play("caution", -4.0)
		return
	if pd.detach:
		detach_part(pname)


func detach_part(pname: String) -> void:
	var pd: Dictionary = parts[pname]
	if not pd.attached:
		return
	pd.attached = false
	pd.hp = 0.0
	for s in _surfaces:
		if s.part == pname:
			s.active = false
	for i in _shape_parts.size():
		if _shape_parts[i] == pname:
			_shape_nodes[i].set_deferred("disabled", true)
	# Mass + centre-of-mass shift toward what remains.
	var frac: float = pd.mass_frac
	var part_c: Vector3 = pd.center
	var new_mass := mass * (1.0 - frac)
	_com = (_com * mass - part_c * mass * frac) / maxf(new_mass, 1.0)
	mass = new_mass
	center_of_mass = _com
	# The visual part becomes a tumbling, burning debris body.
	var node: Node3D = pd.node
	if node != null and is_instance_valid(node):
		var debris := Debris.new()
		get_parent().add_child(debris)
		debris.global_transform = global_transform
		var vel_at := linear_velocity + angular_velocity.cross(global_transform.basis * (part_c - _com))
		var push := (global_transform.basis * Vector3(signf(part_c.x), 0.4, 0.0)).normalized() * randf_range(3.0, 9.0)
		debris.setup_from(node, part_c, vel_at + push, angular_velocity + Vector3(randf_range(-2, 2), randf_range(-2, 2), randf_range(-2, 2)), _base_mass * maxf(frac, 0.01))
	# Torn root: sparks + fire.
	var root_local := _effect_anchor(pname)
	if pname.begins_with("wing"):
		root_local = Vector3(signf(part_c.x) * (1.2 if type_id == "f16" else 2.6), part_c.y, part_c.z)
	Fx.explosion(get_parent(), global_transform * root_local, 0.35, linear_velocity)
	if not fires.has(pname) and (pname.begins_with("wing") or pname.begins_with("engine")):
		var fire := Fx.fire_emitter(1.2 if type_id == "f16" else 1.8)
		fire.position = root_local
		add_child(fire)
		fires[pname] = fire
	Sfx.play_at("tear", global_position, 1.0)
	part_lost.emit(self, pname)
	if is_player:
		CameraRig.add_trauma(0.6)
	# Missiles on a lost wing are gone too.
	if pname.begins_with("wing") and missiles_left > 0:
		var lost := 0
		for m in model.missiles:
			if is_instance_valid(m) and (m as Node3D).visible and (m as Node3D).get_parent() == node:
				lost += 1
		missiles_left = maxi(missiles_left - lost, 0)


func _apply_scorch() -> void:
	for mi in model.root.find_children("*", "MeshInstance3D", true, false):
		var mat := (mi as MeshInstance3D).material_override
		if mat is ShaderMaterial and (mat as ShaderMaterial).shader == AircraftModel.PAINT:
			(mat as ShaderMaterial).set_shader_parameter("scorch", scorch)


## Mid-air destruction: fireball, break-up, burning wreck falls.
func explode() -> void:
	if not alive:
		return
	alive = false
	kill_credit = last_attacker
	throttle = 0.0
	fire_gun = false
	scorch = 1.0
	_apply_scorch()
	Fx.explosion(get_parent(), global_position, 1.6 if type_id == "f16" else 2.6, linear_velocity)
	# Break off a few random pieces.
	for pname in ["wing_l", "wing_r", "tail_h", "tail_v", "engine_l", "engine_r"]:
		if parts.has(pname) and parts[pname].attached and (randf() < 0.6 or pname == "tail_v"):
			detach_part(pname)
	if not fires.has("fuselage"):
		var fire := Fx.fire_emitter(2.5 if type_id == "f16" else 3.5)
		fire.position = parts.fuselage.center
		add_child(fire)
		fires["fuselage"] = fire
	apply_torque_impulse(Vector3(randf_range(-1, 1), randf_range(-0.3, 0.3), randf_range(-1, 1)) * inertia.length() * 0.8)
	destroyed.emit(self)


## Ground/building impact: total loss.
func crash(_cause: String) -> void:
	if crashed:
		return
	var was_alive := alive
	alive = false
	crashed = true
	if was_alive:
		kill_credit = last_attacker
	_final_impact(global_position)
	if was_alive:
		destroyed.emit(self)


func _final_impact(pos: Vector3) -> void:
	crashed = true
	_wreck_burn = 1.0
	var size := (2.2 if type_id == "f16" else 3.4) * clampf(airspeed / 120.0, 0.6, 1.6)
	Fx.explosion(get_parent(), pos, size, linear_velocity * 0.2)
	for pname in parts.keys():
		if parts[pname].attached and parts[pname].detach and randf() < 0.8:
			detach_part(pname)
	# The wreck: hide most of the model, leave a burning scorched hulk.
	model.root.visible = airspeed < 60.0
	for e in smokes.values():
		if is_instance_valid(e):
			(e as GPUParticles3D).emitting = false
	var fire := Fx.fire_emitter(3.0 if type_id == "f16" else 4.5)
	add_child(fire)
	fire.position = Vector3.ZERO
	fires["wreck"] = fire
	for sh in _shape_nodes:
		sh.set_deferred("disabled", true)
	_crash_freeze_timer = 0.05
	fire_gun = false
	if _snd_gun != null:
		_snd_gun.stop()


func total_health() -> float:
	var t := 0.0
	var m := 0.0
	for p in parts.values():
		t += float(p.hp) if p.attached else 0.0
		m += float(p.max)
	return t / maxf(m, 1.0)


func set_cockpit_view(on: bool) -> void:
	model.interior.visible = on
	for n in model.hide_in_cockpit:
		(n as Node3D).visible = not on
