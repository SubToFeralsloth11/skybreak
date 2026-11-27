class_name AircraftModel
extends RefCounted
## Builds the visual model of an aircraft as separable parts (for damage/detachment),
## animated control surfaces, landing gear, cockpit interior and engine exhaust anchors.
##
## Result dictionary:
##   root: Node3D
##   parts: {part_name: Node3D}            (every mesh in body coordinates, node at identity)
##   controls: Array[{node, axis, kind, max}] (kind: "roll_l","roll_r","pitch","yaw","flap","pitch_roll_l","pitch_roll_r")
##   gear: Array[{node, wheel, fold_axis, fold_angle, steer_node}]
##   interior: Node3D (cockpit, only visible in first person)
##   exhausts: Array[{node, part}]          (+Z points out of the nozzle)
##   missiles: Array[Node3D]                (visual rounds on hardpoints, in firing order)
##   hide_in_cockpit: Array[Node3D]
##   nav_lights: Array[Node3D]

const PAINT := preload("res://shaders/aircraft_paint.gdshader")


static func build(id: String, livery := "default") -> Dictionary:
	if id == "heli":
		return _heli(livery)
	if id == "airliner":
		return _airliner(livery)
	return _f16(livery)


# ---------------------------------------------------------------- materials

static func paint_material(scheme: int, base: Color, second: Color, accent: Color, metal := 0.35, rough := 0.5) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = PAINT
	m.set_shader_parameter("scheme", scheme)
	m.set_shader_parameter("base_color", base)
	m.set_shader_parameter("second_color", second)
	m.set_shader_parameter("accent_color", accent)
	m.set_shader_parameter("metallic_amount", metal)
	m.set_shader_parameter("roughness_amount", rough)
	return m


static func std(color: Color, metal := 0.0, rough := 0.6, emission := Color.BLACK, emission_energy := 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.metallic = metal
	m.roughness = rough
	if emission_energy > 0.0:
		m.emission_enabled = true
		m.emission = emission
		m.emission_energy_multiplier = emission_energy
	return m


static func glass(tint: Color, alpha := 0.35) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = Color(tint.r, tint.g, tint.b, alpha)
	m.metallic = 0.9
	m.metallic_specular = 1.0
	m.roughness = 0.04
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m


static func _mi(parent: Node3D, mesh: Mesh, mat: Material, name := "") -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	if name != "":
		mi.name = name
	parent.add_child(mi)
	return mi


static func _part(root: Node3D, parts: Dictionary, name: String) -> Node3D:
	var n := Node3D.new()
	n.name = name
	root.add_child(n)
	parts[name] = n
	return n


## A hinged sub-node: mesh built in body coordinates, node placed at the hinge so it can rotate.
static func _hinged(parent: Node3D, mesh: Mesh, mat: Material, pivot: Vector3) -> Node3D:
	var n := Node3D.new()
	n.position = pivot
	parent.add_child(n)
	var mi := _mi(n, mesh, mat)
	mi.position = -pivot
	return n


static func _nav_light(parent: Node3D, pos: Vector3, color: Color, lights: Array, strobe := false) -> void:
	var bulb := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.07
	sm.height = 0.14
	bulb.mesh = sm
	bulb.material_override = std(color, 0.0, 0.3, color, 6.0)
	bulb.position = pos
	bulb.set_meta("strobe", strobe)
	bulb.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(bulb)
	lights.append(bulb)


static func _missile_mesh(nose: Vector3, length: float, radius: float, body: Material, seeker: Material) -> Node3D:
	var n := Node3D.new()
	var tail := nose + Vector3(0, 0, length)
	_mi(n, MeshKit.cylinder_between(nose + Vector3(0, 0, 0.18), tail, radius, radius, 10), body)
	_mi(n, MeshKit.sphere(nose + Vector3(0, 0, 0.18), Vector3(radius, radius, 0.2), 10, 6), seeker)
	for k in 4:
		var ang := PI * 0.25 + k * PI * 0.5
		var dir := Vector3(cos(ang), sin(ang), 0)
		_mi(n, MeshKit.box(nose + Vector3(0, 0, 0.55) + dir * radius * 2.2, Vector3(0.012, 0.012, 0.012) + (dir * radius * 2.2).abs() + Vector3(0.01, 0.01, 0.22)), body)
		_mi(n, MeshKit.box(tail - Vector3(0, 0, 0.18) + dir * radius * 2.8, Vector3(0.012, 0.012, 0.012) + (dir * radius * 3.0).abs() + Vector3(0.01, 0.01, 0.3)), body)
	return n


static func _wheel(parent: Node3D, center: Vector3, radius: float, width: float, tire: Material, hub: Material) -> void:
	_mi(parent, MeshKit.cylinder_between(center - Vector3(width * 0.5, 0, 0), center + Vector3(width * 0.5, 0, 0), radius, radius, 16), tire)
	_mi(parent, MeshKit.cylinder_between(center - Vector3(width * 0.52, 0, 0), center + Vector3(width * 0.52, 0, 0), radius * 0.55, radius * 0.55, 12), hub)


# ---------------------------------------------------------------- F-16

static func _f16(livery: String) -> Dictionary:
	var root := Node3D.new()
	root.name = "Model"
	var parts := {}
	var controls: Array = []
	var gear: Array = []
	var exhausts: Array = []
	var missiles: Array = []
	var lights: Array = []

	var skin: ShaderMaterial
	if livery == "aggressor":
		skin = paint_material(3, Color(0.62, 0.6, 0.52), Color(0.42, 0.36, 0.3), Color(0.3, 0.33, 0.28), 0.3, 0.55)
	else:
		skin = paint_material(1, Color(0.6, 0.62, 0.64), Color(0.45, 0.48, 0.51), Color(0.2, 0.2, 0.2), 0.32, 0.5)
	var dark := std(Color(0.06, 0.06, 0.065), 0.4, 0.5)
	var metal := std(Color(0.35, 0.33, 0.3), 0.9, 0.35)
	var radome := std(Color(0.5, 0.52, 0.54), 0.1, 0.55)
	var canopy := glass(Color(0.55, 0.45, 0.2), 0.42)
	var tire := std(Color(0.04, 0.04, 0.04), 0.0, 0.9)
	var white := std(Color(0.85, 0.85, 0.85), 0.1, 0.5)
	var missile_body := std(Color(0.86, 0.86, 0.84), 0.2, 0.45)
	var seeker := std(Color(0.25, 0.35, 0.45), 0.6, 0.1)

	# --- cockpit / nose section
	var cp := _part(root, parts, "cockpit")
	_mi(cp, MeshKit.loft([
		[-7.9, 0.12, 0.02, 0.02], [-7.5, 0.12, 0.2, 0.2], [-6.7, 0.1, 0.38, 0.38], [-5.7, 0.1, 0.52, 0.53],
		[-4.7, 0.12, 0.6, 0.64, 0.2], [-3.4, 0.12, 0.68, 0.72, 0.3]], 24, true, false), skin)
	_mi(cp, MeshKit.loft([[-7.95, 0.12, 0.01, 0.01], [-7.85, 0.12, 0.12, 0.12], [-7.2, 0.11, 0.3, 0.3], [-6.9, 0.1, 0.35, 0.35]], 16), radome)
	_mi(cp, MeshKit.cylinder_between(Vector3(0, 0.12, -8.7), Vector3(0, 0.12, -7.9), 0.02, 0.04, 6), metal)
	_mi(cp, MeshKit.sphere(Vector3(0, 0.74, -4.15), Vector3(0.43, 0.5, 1.65), 20, 12), canopy)
	_mi(cp, MeshKit.loft([[-2.7, 0.72, 0.4, 0.35], [-2.55, 0.75, 0.42, 0.38]], 16), dark) # canopy bow
	# --- main fuselage
	var fu := _part(root, parts, "fuselage")
	_mi(fu, MeshKit.loft([
		[-3.4, 0.12, 0.68, 0.72, 0.3], [-2.2, 0.06, 0.78, 0.8, 0.4], [-0.5, 0.0, 0.86, 0.85, 0.45], [1.5, 0.0, 0.86, 0.85, 0.45],
		[3.5, 0.05, 0.8, 0.8, 0.4], [5.0, 0.1, 0.7, 0.7, 0.3], [6.3, 0.1, 0.6, 0.6, 0.1], [7.0, 0.1, 0.55, 0.55]], 24, false, true), skin)
	# Spine behind the canopy
	_mi(fu, MeshKit.loft([[-2.9, 0.62, 0.05, 0.05], [-2.5, 0.68, 0.36, 0.22], [0.0, 0.7, 0.42, 0.25], [3.0, 0.68, 0.38, 0.2], [5.4, 0.55, 0.2, 0.1]], 16), skin)
	# Chin intake
	_mi(fu, MeshKit.loft([[-2.75, -0.86, 0.56, 0.38, 0.6], [-1.6, -0.78, 0.58, 0.4, 0.6], [0.5, -0.55, 0.5, 0.35, 0.5], [2.0, -0.4, 0.3, 0.2]], 20, false, true), skin)
	_mi(fu, MeshKit.loft([[-2.74, -0.86, 0.5, 0.32, 0.6], [-2.6, -0.84, 0.5, 0.32, 0.6]], 20), dark)
	# Strakes (LERX)
	for side in [-1.0, 1.0]:
		var lerx := MeshKit.wing(Vector3(0.62, 0.0, -4.6), 5.9, Vector3(1.32, 0.0, -1.5), 2.9, 0.035)
		_mi(fu, lerx if side > 0 else MeshKit.mirror_x(lerx), skin)
	# Ventral fins
	for side in [-1.0, 1.0]:
		var vf := MeshKit.wing(Vector3(0.55, -0.6, 3.6), 1.4, Vector3(0.78, -1.15, 4.3), 0.8, 0.06, Vector3.RIGHT, 2)
		_mi(fu, vf if side > 0 else MeshKit.mirror_x(vf), skin)
	_nav_light(fu, Vector3(0, 0.9, 1.0), Color(1, 0.15, 0.1), lights, true) # anti-collision beacon

	# --- wings with flaperons, wingtip rails, pylons
	for side in [-1, 1]:
		var pname := "wing_l" if side < 0 else "wing_r"
		var w := _part(root, parts, pname)
		var inner := MeshKit.wing(Vector3(1.3, 0.0, -1.5), 3.9, Vector3(3.2, 0.0, 0.37), 1.97, 0.04)
		var outer := MeshKit.wing(Vector3(3.2, 0.0, 0.37), 2.67, Vector3(4.75, 0.0, 1.85), 1.15, 0.035)
		var flap := MeshKit.wing(Vector3(1.32, 0.0, 2.38), 0.72, Vector3(3.2, 0.0, 2.32), 0.72, 0.06)
		var rail := MeshKit.box(Vector3(4.82, 0.0, 2.0), Vector3(0.1, 0.16, 2.6))
		var pylon_a := MeshKit.box(Vector3(3.0, -0.22, 0.9), Vector3(0.1, 0.36, 1.6))
		var pylon_b := MeshKit.box(Vector3(3.95, -0.18, 1.5), Vector3(0.08, 0.28, 1.3))
		if side < 0:
			inner = MeshKit.mirror_x(inner); outer = MeshKit.mirror_x(outer); flap = MeshKit.mirror_x(flap)
			rail = MeshKit.mirror_x(rail); pylon_a = MeshKit.mirror_x(pylon_a); pylon_b = MeshKit.mirror_x(pylon_b)
		_mi(w, inner, skin)
		_mi(w, outer, skin)
		_mi(w, MeshKit.merge([rail, pylon_a, pylon_b]), skin)
		var hinge := Vector3(1.32 * side, 0.0, 2.38)
		var hinge_tip := Vector3(3.2 * side, 0.0, 2.32)
		var fl := _hinged(w, flap, skin, hinge)
		var axis := (hinge_tip - hinge).normalized()
		controls.append({"node": fl, "axis": axis, "kind": "roll_l" if side < 0 else "roll_r", "max": deg_to_rad(21.0)})
		controls.append({"node": fl, "axis": axis, "kind": "flap", "max": deg_to_rad(20.0)})
		_nav_light(w, Vector3(4.78 * side, 0.12, 0.9), Color(1, 0.1, 0.05) if side < 0 else Color(0.1, 1, 0.2), lights)
		# Missiles: wingtip AIM-9, outer pylon, inner pylon
		for spot in [Vector3(4.92 * side, 0.0, 0.6), Vector3(3.95 * side, -0.42, 0.3), Vector3(3.0 * side, -0.52, -0.3)]:
			var ms := _missile_mesh(spot, 2.9, 0.064, missile_body, seeker)
			w.add_child(ms)
			missiles.append(ms)
	# Interleave so launches alternate sides (tips first).
	missiles = [missiles[0], missiles[3], missiles[1], missiles[4], missiles[2], missiles[5]]

	# --- horizontal stabilators (all-moving)
	var th := _part(root, parts, "tail_h")
	for side in [-1, 1]:
		var stab := MeshKit.wing(Vector3(0.62, -0.1, 4.6), 2.5, Vector3(2.8, -0.22, 6.3), 0.9, 0.04)
		if side < 0:
			stab = MeshKit.mirror_x(stab)
		var pivot := Vector3(1.0 * side, -0.12, 5.75)
		var sn := _hinged(th, stab, skin, pivot)
		controls.append({"node": sn, "axis": Vector3.RIGHT, "kind": "pitch", "max": deg_to_rad(25.0)})
		controls.append({"node": sn, "axis": Vector3.RIGHT, "kind": "pitch_roll_l" if side < 0 else "pitch_roll_r", "max": deg_to_rad(8.0)})
	# --- vertical fin + rudder
	var tv := _part(root, parts, "tail_v")
	_mi(tv, MeshKit.wing(Vector3(0, 0.72, 3.3), 2.7, Vector3(0, 3.25, 5.9), 0.5, 0.05, Vector3.RIGHT), skin)
	_mi(tv, MeshKit.box(Vector3(0, 0.95, 5.0), Vector3(0.3, 0.5, 2.6)), skin) # fin root fairing
	var rud := _hinged(tv, MeshKit.wing(Vector3(0, 0.78, 6.0), 0.75, Vector3(0, 3.2, 6.4), 0.68, 0.05, Vector3.RIGHT, 2), skin, Vector3(0, 0.78, 6.0))
	controls.append({"node": rud, "axis": (Vector3(0, 3.2, 6.4) - Vector3(0, 0.78, 6.0)).normalized(), "kind": "yaw", "max": deg_to_rad(30.0)})
	_nav_light(tv, Vector3(0, 3.3, 6.3), Color(1, 1, 1), lights)
	# --- engine nozzle
	var en := _part(root, parts, "engine")
	_mi(en, MeshKit.cylinder_between(Vector3(0, 0.1, 6.9), Vector3(0, 0.1, 7.95), 0.56, 0.47, 20), metal)
	_mi(en, MeshKit.cylinder_between(Vector3(0, 0.1, 7.6), Vector3(0, 0.1, 7.9), 0.42, 0.42, 16), std(Color(0.12, 0.1, 0.09), 0.7, 0.6))
	var ex := Node3D.new()
	ex.position = Vector3(0, 0.1, 7.75)
	en.add_child(ex)
	exhausts.append({"node": ex, "part": "engine", "radius": 0.44})

	# --- landing gear
	var specs := AircraftSpec.get_spec("f16")
	for wd in specs.wheels:
		var attach: Vector3 = wd.pos
		var leg := Node3D.new()
		leg.position = attach
		root.add_child(leg)
		var steer := Node3D.new()
		leg.add_child(steer)
		var rest := -(float(wd.travel) - 0.14)
		_mi(steer, MeshKit.cylinder_between(Vector3.ZERO, Vector3(0, rest + float(wd.radius) * 0.4, 0), 0.07, 0.06, 8), white)
		_wheel(steer, Vector3(0, rest + 0.0, 0), wd.radius, 0.22 if wd.name == "nose" else 0.28, tire, white)
		var fold_axis := Vector3.RIGHT if wd.name == "nose" else Vector3.FORWARD * (-1.0 if attach.x < 0.0 else 1.0)
		gear.append({"node": leg, "wheel": wd.name, "fold_axis": fold_axis, "fold_angle": deg_to_rad(95.0), "steer_node": steer, "rest": rest})

	var interior := _f16_cockpit()
	root.add_child(interior)

	return {
		"root": root, "parts": parts, "controls": controls, "gear": gear, "interior": interior,
		"exhausts": exhausts, "missiles": missiles, "hide_in_cockpit": [parts["cockpit"]], "nav_lights": lights,
	}

# ---------------------------------------------------------------- Helicopter (AH-6 style)

static func _heli(_livery: String) -> Dictionary:
	var root := Node3D.new()
	root.name = "Model"
	var parts := {}
	var lights: Array = []
	var missiles: Array = []
	var body := std(Color(0.12, 0.13, 0.14), 0.3, 0.45)
	var stripe := std(Color(0.95, 0.55, 0.08), 0.2, 0.4)
	var metal := std(Color(0.35, 0.36, 0.38), 0.8, 0.35)
	var dark := std(Color(0.05, 0.05, 0.05), 0.2, 0.7)
	# --- egg-shaped cabin
	var fus := _part(root, parts, "fuselage")
	_mi(fus, MeshKit.sphere(Vector3(0, 0, 0.1), Vector3(0.78, 0.72, 1.55), 20, 14), body)
	_mi(fus, MeshKit.box(Vector3(0, -0.05, 0.1), Vector3(1.58, 0.08, 1.6)), stripe)
	# skids + struts
	for sx in [-1.0, 1.0]:
		_mi(fus, MeshKit.cylinder_between(Vector3(sx * 1.0, -1.1, -1.7), Vector3(sx * 1.0, -1.1, 1.6), 0.05, 0.05, 8), metal)
		_mi(fus, MeshKit.cylinder_between(Vector3(sx * 1.0, -1.1, -1.7), Vector3(sx * 1.0, -0.95, -2.0), 0.05, 0.05, 8), metal)
		for sz in [-0.9, 0.9]:
			_mi(fus, MeshKit.cylinder_between(Vector3(sx * 1.0, -1.1, sz), Vector3(sx * 0.5, -0.5, sz), 0.04, 0.04, 6), metal)
		_nav_light(fus, Vector3(sx * 0.8, 0.0, 0.3), Color(0, 1, 0) if sx > 0 else Color(1, 0, 0), lights)
	# --- canopy
	var ck := _part(root, parts, "cockpit")
	_mi(ck, MeshKit.sphere(Vector3(0, 0.12, -0.75), Vector3(0.72, 0.6, 0.95), 18, 12), glass(Color(0.3, 0.45, 0.55), 0.45))
	# --- engine hump
	var en := _part(root, parts, "engine")
	_mi(en, MeshKit.sphere(Vector3(0, 0.72, 0.5), Vector3(0.45, 0.3, 0.9), 14, 8), body)
	_mi(en, MeshKit.cylinder_between(Vector3(0, 0.65, 1.3), Vector3(0, 0.6, 1.6), 0.16, 0.13, 10), dark)
	# rocket pods (missiles)
	for sx in [-1.0, 1.0]:
		_mi(fus, MeshKit.box(Vector3(sx * 0.95, -0.25, 0.2), Vector3(0.6, 0.06, 0.25)), metal)
		var pod := _missile_mesh(Vector3(sx * 1.3, -0.35, -0.7), 1.6, 0.09, std(Color(0.8, 0.8, 0.78), 0.3, 0.5), dark)
		fus.add_child(pod)
		missiles.append(pod)
		var pod2 := _missile_mesh(Vector3(sx * 1.3, -0.15, -0.6), 1.5, 0.08, std(Color(0.8, 0.8, 0.78), 0.3, 0.5), dark)
		fus.add_child(pod2)
		missiles.append(pod2)
	# --- tail boom, fins and tail rotor
	var tv := _part(root, parts, "tail_v")
	_mi(tv, MeshKit.cylinder_between(Vector3(0, 0.25, 1.3), Vector3(0, 0.4, 5.4), 0.24, 0.09, 12), body)
	_mi(tv, MeshKit.box(Vector3(0, 0.75, 5.25), Vector3(0.06, 0.95, 0.55)), stripe)
	_mi(tv, MeshKit.box(Vector3(0, 0.15, 4.6), Vector3(1.2, 0.05, 0.4)), body)
	_nav_light(tv, Vector3(0, 1.25, 5.35), Color(1, 1, 1), lights, true)
	var tail_rotor := Node3D.new()
	tail_rotor.position = Vector3(0.14, 0.45, 5.3)
	tv.add_child(tail_rotor)
	_mi(tail_rotor, MeshKit.box(Vector3.ZERO, Vector3(0.03, 1.1, 0.12)), dark)
	_mi(tail_rotor, MeshKit.box(Vector3.ZERO, Vector3(0.03, 0.12, 1.1)), dark)
	# --- main rotor: mast, hub, 5 blades + motion-blur disc
	var rp := _part(root, parts, "rotor")
	_mi(rp, MeshKit.cylinder_between(Vector3(0, 0.9, 0.2), Vector3(0, 1.35, 0.2), 0.07, 0.07, 8), metal)
	var rotor := Node3D.new()
	rotor.position = Vector3(0, 1.35, 0.2)
	rp.add_child(rotor)
	_mi(rotor, MeshKit.cylinder_between(Vector3(0, -0.06, 0), Vector3(0, 0.08, 0), 0.18, 0.14, 10), metal)
	for k in 5:
		var blade := Node3D.new()
		blade.rotation.y = TAU * k / 5.0
		rotor.add_child(blade)
		_mi(blade, MeshKit.box(Vector3(0, 0, -2.0), Vector3(0.24, 0.035, 3.8)), dark)
	var disc := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 3.9
	cm.bottom_radius = 3.9
	cm.height = 0.02
	cm.radial_segments = 40
	disc.mesh = cm
	var dm := StandardMaterial3D.new()
	dm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	dm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	dm.cull_mode = BaseMaterial3D.CULL_DISABLED
	dm.albedo_color = Color(0.05, 0.05, 0.05, 0.0)
	disc.material_override = dm
	disc.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	disc.position = Vector3(0, 1.35, 0.2)
	rp.add_child(disc)
	var interior := Node3D.new()
	root.add_child(interior)
	return {
		"root": root, "parts": parts, "controls": [], "gear": [], "interior": interior,
		"exhausts": [], "missiles": missiles, "hide_in_cockpit": [parts["cockpit"]], "nav_lights": lights,
		"rotor": rotor, "rotor_disc": disc, "tail_rotor": tail_rotor,
	}



static func _f16_cockpit() -> Node3D:
	var c := Node3D.new()
	c.name = "Interior"
	var panel_mat := std(Color(0.11, 0.115, 0.12), 0.1, 0.8)
	var frame := std(Color(0.05, 0.05, 0.055), 0.3, 0.5)
	var screen := std(Color(0.02, 0.05, 0.03), 0.0, 0.3, Color(0.1, 0.45, 0.2), 0.6)
	var hud_glass := glass(Color(0.4, 0.9, 0.5), 0.12)
	# Instrument panel and glareshield
	_mi(c, MeshKit.box(Vector3(0, 0.48, -4.75), Vector3(0.95, 0.42, 0.12)), panel_mat)
	_mi(c, MeshKit.box(Vector3(0, 0.71, -4.62), Vector3(0.7, 0.05, 0.34)), frame)
	_mi(c, MeshKit.box(Vector3(-0.22, 0.48, -4.685), Vector3(0.22, 0.2, 0.01)), screen)
	_mi(c, MeshKit.box(Vector3(0.22, 0.48, -4.685), Vector3(0.22, 0.2, 0.01)), screen)
	# HUD combiner
	_mi(c, MeshKit.box(Vector3(0, 0.92, -4.48), Vector3(0.2, 0.22, 0.008)), hud_glass)
	_mi(c, MeshKit.box(Vector3(-0.105, 0.86, -4.5), Vector3(0.012, 0.3, 0.02)), frame)
	_mi(c, MeshKit.box(Vector3(0.105, 0.86, -4.5), Vector3(0.012, 0.3, 0.02)), frame)
	# Side consoles
	_mi(c, MeshKit.box(Vector3(-0.47, 0.38, -3.7), Vector3(0.2, 0.12, 1.4)), panel_mat)
	_mi(c, MeshKit.box(Vector3(0.47, 0.38, -3.7), Vector3(0.2, 0.12, 1.4)), panel_mat)
	# Side stick + throttle
	_mi(c, MeshKit.cylinder_between(Vector3(0.47, 0.44, -3.95), Vector3(0.47, 0.6, -3.97), 0.02, 0.025, 8), frame)
	_mi(c, MeshKit.box(Vector3(-0.47, 0.5, -3.75), Vector3(0.05, 0.1, 0.12)), frame)
	# Canopy rails and ejection-seat headrest
	_mi(c, MeshKit.box(Vector3(-0.42, 0.62, -3.9), Vector3(0.04, 0.04, 2.6)), frame)
	_mi(c, MeshKit.box(Vector3(0.42, 0.62, -3.9), Vector3(0.04, 0.04, 2.6)), frame)
	_mi(c, MeshKit.box(Vector3(0, 0.95, -3.05), Vector3(0.36, 0.42, 0.2)), std(Color(0.12, 0.12, 0.1), 0.0, 0.9))
	_mi(c, MeshKit.loft([[-2.75, 0.72, 0.41, 0.36], [-2.6, 0.74, 0.43, 0.38]], 16), frame)
	return c


# ---------------------------------------------------------------- Airliner

static func _airliner(_livery: String) -> Dictionary:
	var root := Node3D.new()
	root.name = "Model"
	var parts := {}
	var controls: Array = []
	var gear: Array = []
	var exhausts: Array = []
	var lights: Array = []

	var skin := paint_material(2, Color(0.93, 0.94, 0.95), Color(0.62, 0.65, 0.68), Color(0.07, 0.2, 0.52), 0.15, 0.35)
	skin.set_shader_parameter("window_band", Vector4(0.55, 0.36, -12.6, 11.5))
	skin.set_shader_parameter("belly_y", -0.9)
	skin.set_shader_parameter("tail_z", 11.0)
	skin.set_shader_parameter("panel_scale", 0.9)
	var wing_mat := paint_material(0, Color(0.74, 0.76, 0.78), Color(0.6, 0.6, 0.6), Color(0.2, 0.2, 0.2), 0.45, 0.4)
	var nacelle := paint_material(0, Color(0.9, 0.91, 0.92), Color(0.6, 0.6, 0.6), Color(0.2, 0.2, 0.2), 0.2, 0.3)
	var metal := std(Color(0.7, 0.7, 0.72), 0.95, 0.2)
	var dark := std(Color(0.04, 0.04, 0.045), 0.3, 0.6)
	var cockpit_glass := std(Color(0.03, 0.04, 0.05), 0.6, 0.05)
	var tire := std(Color(0.04, 0.04, 0.04), 0.0, 0.9)
	var gear_mat := std(Color(0.75, 0.75, 0.75), 0.6, 0.4)
	var tail_mat := paint_material(0, Color(0.07, 0.2, 0.52), Color(0.07, 0.2, 0.52), Color(0.95, 0.75, 0.2), 0.2, 0.35)

	# --- nose / cockpit section
	var cp := _part(root, parts, "cockpit")
	_mi(cp, MeshKit.loft([
		[-18.6, -0.55, 0.05, 0.05], [-18.25, -0.5, 0.62, 0.56], [-17.5, -0.38, 1.17, 1.1], [-16.3, -0.22, 1.6, 1.56],
		[-14.9, -0.08, 1.88, 1.86], [-13.0, 0.0, 1.98, 1.98]], 28, true, false), skin)
	_mi(cp, _windscreen_mesh(), cockpit_glass)
	# --- fuselage
	var fu := _part(root, parts, "fuselage")
	_mi(fu, MeshKit.loft([
		[-13.0, 0.0, 1.98, 1.98], [-6.0, 0.0, 1.98, 1.98], [2.0, 0.0, 1.98, 1.98], [9.0, 0.0, 1.98, 1.98], [11.5, 0.25, 1.8, 1.72],
		[14.0, 0.62, 1.42, 1.3], [16.5, 1.02, 0.92, 0.82], [18.5, 1.32, 0.46, 0.42], [19.45, 1.42, 0.14, 0.14]], 28, false, true), skin)
	# Wing-body fairing (belly)
	_mi(fu, MeshKit.loft([[-6.5, -1.4, 0.4, 0.3, 0.6], [-4.5, -1.55, 2.2, 0.8, 0.7], [3.0, -1.55, 2.3, 0.85, 0.7], [5.5, -1.4, 0.6, 0.4, 0.6]], 20), skin)
	_mi(fu, MeshKit.box(Vector3(0, -0.2, 16.9), Vector3(0.5, 0.5, 2.0)), skin) # APU fairing
	_nav_light(fu, Vector3(0, 2.05, -2.0), Color(1, 0.15, 0.1), lights, true)
	_nav_light(fu, Vector3(0, -2.35, 1.0), Color(1, 0.15, 0.1), lights, true)

	# --- wings (inner + outer panel, flaps, ailerons, sharklets)
	for side in [-1, 1]:
		var pname := "wing_l" if side < 0 else "wing_r"
		var w := _part(root, parts, pname)
		var pieces: Array = []
		# inner panel: x 1.9 -> 6.2
		pieces.append(MeshKit.wing(Vector3(1.9, -1.35, -4.6), 7.0 * 0.78, Vector3(6.2, -0.98, -2.35), 4.4 * 0.78, 0.15))
		# outer panel to tip, split for flap / aileron sections
		pieces.append(MeshKit.wing(Vector3(6.2, -0.98, -2.35), 4.4 * 0.78, Vector3(12.6, -0.42, 1.0), 2.6 * 0.78, 0.13))
		pieces.append(MeshKit.wing(Vector3(12.6, -0.42, 1.0), 2.6 * 0.78, Vector3(17.0, -0.04, 3.3), 1.5, 0.11))
		pieces.append(MeshKit.wing(Vector3(17.0, -0.04, 3.3), 1.5, Vector3(17.35, 2.3, 4.7), 0.6, 0.08, Vector3.RIGHT, 3)) # sharklet
		var wing_mesh := MeshKit.merge(pieces)
		if side < 0:
			wing_mesh = MeshKit.mirror_x(wing_mesh)
		_mi(w, wing_mesh, wing_mat)
		# Flaps (two sections) and aileron
		var sections := [
			[Vector3(1.95, -1.33, -4.6 + 7.0 * 0.76), 7.0 * 0.25, Vector3(6.2, -0.97, -2.35 + 4.4 * 0.76), 4.4 * 0.25, "flap"],
			[Vector3(6.2, -0.97, -2.35 + 4.4 * 0.76), 4.4 * 0.25, Vector3(12.6, -0.41, 1.0 + 2.6 * 0.76), 2.6 * 0.25, "flap"],
			[Vector3(12.6, -0.41, 1.0 + 2.6 * 0.76), 2.6 * 0.24, Vector3(16.4, -0.08, 3.0 + 1.6 * 0.6), 0.55, "aileron"],
		]
		for s in sections:
			var a: Vector3 = s[0]
			var b: Vector3 = s[2]
			var m := MeshKit.wing(a, s[1], b, s[3], 0.07, Vector3.UP, 2)
			if side < 0:
				m = MeshKit.mirror_x(m)
				a.x = -a.x
				b.x = -b.x
			var node := _hinged(w, m, wing_mat, a)
			var axis := (b - a).normalized()
			if s[4] == "flap":
				controls.append({"node": node, "axis": axis, "kind": "flap", "max": deg_to_rad(35.0), "slide": 0.9})
			else:
				controls.append({"node": node, "axis": axis, "kind": "roll_l" if side < 0 else "roll_r", "max": deg_to_rad(25.0)})
		_nav_light(w, Vector3(17.1 * side, 0.0, 3.0), Color(1, 0.1, 0.05) if side < 0 else Color(0.1, 1, 0.2), lights)
		_nav_light(w, Vector3(17.2 * side, 0.05, 4.6), Color(1, 1, 1), lights, true)

	# --- engines (detachable)
	for side in [-1, 1]:
		var ename := "engine_l" if side < 0 else "engine_r"
		var e := _part(root, parts, ename)
		var cx: float = 5.75 * side
		_mi(e, MeshKit.loft([
			[-4.9, -2.1, 1.0, 1.0, 0.0, cx], [-4.6, -2.1, 1.08, 1.08, 0.0, cx], [-3.6, -2.1, 1.1, 1.1, 0.0, cx], [-1.6, -2.08, 0.9, 0.9, 0.0, cx],
			[-0.6, -2.06, 0.72, 0.72, 0.0, cx]], 28, false, true), nacelle)
		_mi(e, MeshKit.loft([[-4.92, -2.1, 1.0, 1.0, 0.0, cx], [-4.8, -2.1, 0.9, 0.9, 0.0, cx], [-4.4, -2.1, 0.88, 0.88, 0.0, cx]], 28, false, false), metal) # inlet lip
		_mi(e, MeshKit.loft([[-4.4, -2.1, 0.88, 0.88, 0.0, cx], [-4.35, -2.1, 0.05, 0.05, 0.0, cx]], 24, false, false), dark) # fan face
		_mi(e, MeshKit.loft([[-4.75, -2.1, 0.02, 0.02, 0.0, cx], [-4.4, -2.1, 0.28, 0.28, 0.0, cx]], 12), metal) # spinner
		_mi(e, MeshKit.loft([[-0.6, -2.06, 0.5, 0.5, 0.0, cx], [0.4, -2.06, 0.3, 0.3, 0.0, cx], [0.9, -2.06, 0.04, 0.04, 0.0, cx]], 16), metal) # plug
		var pylon := MeshKit.wing(Vector3(5.75, -1.25, -4.0), 4.6, Vector3(5.75, -0.95, -2.9), 3.5, 0.12, Vector3.RIGHT, 2)
		_mi(e, pylon if side > 0 else MeshKit.mirror_x(pylon), wing_mat)
		var ex := Node3D.new()
		ex.position = Vector3(cx, -2.06, -0.3)
		e.add_child(ex)
		exhausts.append({"node": ex, "part": ename, "radius": 0.6})

	# --- tail
	var th := _part(root, parts, "tail_h")
	for side in [-1, 1]:
		var stab := MeshKit.wing(Vector3(0.9, 1.05, 14.4), 3.7 * 0.72, Vector3(6.3, 1.45, 17.4), 1.5 * 0.72, 0.1)
		var elev := MeshKit.wing(Vector3(0.95, 1.05, 14.4 + 3.7 * 0.7), 3.7 * 0.3, Vector3(6.2, 1.45, 17.4 + 1.5 * 0.68), 1.5 * 0.32, 0.07, Vector3.UP, 2)
		var hp := Vector3(0.95 * side, 1.05, 14.4 + 3.7 * 0.7)
		var tip := Vector3(6.2 * side, 1.45, 17.4 + 1.5 * 0.68)
		if side < 0:
			stab = MeshKit.mirror_x(stab)
			elev = MeshKit.mirror_x(elev)
		_mi(th, stab, wing_mat)
		var en := _hinged(th, elev, wing_mat, hp)
		controls.append({"node": en, "axis": (tip - hp).normalized(), "kind": "pitch", "max": deg_to_rad(25.0)})
	var tv := _part(root, parts, "tail_v")
	_mi(tv, MeshKit.wing(Vector3(0, 1.4, 11.2), 6.4 * 0.72, Vector3(0, 8.1, 16.9), 2.4 * 0.72, 0.1, Vector3.RIGHT), tail_mat)
	var rud_a := Vector3(0, 1.5, 11.2 + 6.4 * 0.7)
	var rud_b := Vector3(0, 7.9, 16.9 + 2.4 * 0.68)
	var rud := _hinged(tv, MeshKit.wing(rud_a, 6.4 * 0.3, rud_b, 2.4 * 0.32, 0.07, Vector3.RIGHT, 2), tail_mat, rud_a)
	controls.append({"node": rud, "axis": (rud_b - rud_a).normalized(), "kind": "yaw", "max": deg_to_rad(30.0)})
	_nav_light(tv, Vector3(0, 1.45, 19.5), Color(1, 1, 1), lights)

	# --- landing gear
	var spec := AircraftSpec.get_spec("airliner")
	for wd in spec.wheels:
		var attach: Vector3 = wd.pos
		var leg := Node3D.new()
		leg.position = attach
		root.add_child(leg)
		var steer := Node3D.new()
		leg.add_child(steer)
		var rest := -(float(wd.travel) - (0.12 if wd.name == "nose" else 0.22))
		var r: float = wd.radius
		_mi(steer, MeshKit.cylinder_between(Vector3.ZERO, Vector3(0, rest + r * 0.3, 0), 0.13, 0.11, 10), gear_mat)
		var spread := 0.35 if wd.name == "nose" else 0.55
		for s2 in [-1.0, 1.0]:
			if wd.name == "nose":
				_wheel(steer, Vector3(s2 * spread, rest, 0), r, 0.25, tire, gear_mat)
			else:
				_wheel(steer, Vector3(s2 * spread, rest, 0), r, 0.4, tire, gear_mat)
		_mi(steer, MeshKit.cylinder_between(Vector3(-spread, rest, 0), Vector3(spread, rest, 0), 0.08, 0.08, 8), gear_mat)
		var fold_axis := Vector3.RIGHT if wd.name == "nose" else Vector3.FORWARD * (-1.0 if attach.x < 0.0 else 1.0)
		gear.append({"node": leg, "wheel": wd.name, "fold_axis": fold_axis, "fold_angle": deg_to_rad(92.0), "steer_node": steer, "rest": rest})

	var interior := _airliner_cockpit()
	root.add_child(interior)
	return {
		"root": root, "parts": parts, "controls": controls, "gear": gear, "interior": interior,
		"exhausts": exhausts, "missiles": [], "hide_in_cockpit": [parts["cockpit"]], "nav_lights": lights,
	}


static func _windscreen_mesh() -> ArrayMesh:
	# Dark glazing band hugging the nose: a thin loft slightly outside the skin, upper half only.
	var rings: Array = []
	var zs := [-17.25, -16.7, -16.15, -15.6]
	var r_w := [1.28, 1.5, 1.66, 1.77]
	var r_h := [1.22, 1.45, 1.62, 1.74]
	var cy := [-0.34, -0.27, -0.21, -0.15]
	for i in zs.size():
		var ring := PackedVector3Array()
		for j in 9:
			var a := lerpf(-1.05, 1.05, float(j) / 8.0)
			ring.append(Vector3(sin(a) * r_w[i] * 1.012, cy[i] + cos(a) * r_h[i] * 1.012, zs[i]))
		rings.append(ring)
	# Only the upper strip: keep y within a band by clamping rings into a thin shell.
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in rings.size() - 1:
		for j in 8:
			var p00: Vector3 = rings[i][j]
			var p01: Vector3 = rings[i][j + 1]
			var p10: Vector3 = rings[i + 1][j]
			var p11: Vector3 = rings[i + 1][j + 1]
			if p00.y < 0.15 or p01.y < 0.15:
				continue
			var n := (p10 - p00).cross(p01 - p00).normalized()
			if n.dot(Vector3(p00.x, p00.y - cy[i], 0)) < 0:
				n = -n
			for p in [p00, p01, p11, p00, p11, p10]:
				st.set_normal(n)
				st.add_vertex(p)
	var m := st.commit()
	return m


static func _airliner_cockpit() -> Node3D:
	var c := Node3D.new()
	c.name = "Interior"
	var panel := std(Color(0.2, 0.21, 0.23), 0.05, 0.85)
	var frame := std(Color(0.16, 0.17, 0.18), 0.1, 0.7)
	var screen := std(Color(0.01, 0.015, 0.03), 0.0, 0.25, Color(0.05, 0.12, 0.3), 0.5)
	var seat := std(Color(0.1, 0.11, 0.13), 0.0, 0.9)
	# Glareshield + main panel
	_mi(c, MeshKit.box(Vector3(0, 0.12, -16.55), Vector3(2.7, 0.12, 0.6)), frame)
	_mi(c, MeshKit.box(Vector3(0, -0.25, -16.6), Vector3(2.7, 0.62, 0.15)), panel)
	for x in [-1.1, -0.58, 0.58, 1.1]:
		_mi(c, MeshKit.box(Vector3(x, -0.22, -16.52), Vector3(0.44, 0.42, 0.01)), screen)
	_mi(c, MeshKit.box(Vector3(0, -0.45, -16.52), Vector3(0.38, 0.32, 0.01)), screen)
	# Pedestal with thrust levers
	_mi(c, MeshKit.box(Vector3(0, -0.55, -15.6), Vector3(0.55, 0.35, 1.5)), panel)
	_mi(c, MeshKit.box(Vector3(-0.08, -0.3, -15.85), Vector3(0.05, 0.18, 0.06)), frame)
	_mi(c, MeshKit.box(Vector3(0.08, -0.3, -15.85), Vector3(0.05, 0.18, 0.06)), frame)
	# Window frame posts: centre post, side posts, top frame
	_mi(c, MeshKit.box(Vector3(0, 0.6, -16.82), Vector3(0.09, 0.95, 0.08)), frame)
	for side in [-1.0, 1.0]:
		var post := MeshKit.box(Vector3(side * 0.88, 0.62, -16.52), Vector3(0.08, 0.95, 0.08))
		_mi(c, post, frame)
		_mi(c, MeshKit.box(Vector3(side * 1.45, 0.62, -15.95), Vector3(0.08, 0.95, 0.08)), frame)
		_mi(c, MeshKit.box(Vector3(side * 1.66, 0.62, -14.9), Vector3(0.08, 0.95, 0.12)), frame)
		# Side walls below windows
		_mi(c, MeshKit.box(Vector3(side * 1.6, -0.35, -15.2), Vector3(0.12, 0.9, 2.4)), panel)
		# Side consoles / tiller
		_mi(c, MeshKit.box(Vector3(side * 1.25, -0.42, -15.1), Vector3(0.35, 0.12, 0.9)), panel)
		# Sidestick
		_mi(c, MeshKit.cylinder_between(Vector3(side * 1.28, -0.36, -15.3), Vector3(side * 1.28, -0.22, -15.33), 0.025, 0.03, 8), frame)
	_mi(c, MeshKit.box(Vector3(0, 1.17, -16.0), Vector3(2.9, 0.08, 1.9)), panel) # roof
	_mi(c, MeshKit.box(Vector3(0, 1.08, -15.4), Vector3(1.0, 0.1, 1.2)), frame) # overhead panel
	_mi(c, MeshKit.box(Vector3(0, 0.42, -17.05), Vector3(1.8, 0.06, 0.06)), frame) # windscreen bottom
	_mi(c, MeshKit.box(Vector3(0, 1.08, -16.9), Vector3(1.9, 0.12, 0.12)), frame) # windscreen top
	# Seats
	for side in [-1.0, 1.0]:
		_mi(c, MeshKit.box(Vector3(side * 0.55, -0.6, -14.75), Vector3(0.55, 0.12, 0.55)), seat)
		_mi(c, MeshKit.box(Vector3(side * 0.55, -0.1, -14.45), Vector3(0.55, 0.9, 0.12)), seat)
	return c
