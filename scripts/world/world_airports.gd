class_name WorldAirports
extends RefCounted
## Runways (procedural markings shader), taxiways, aprons, terminals, towers, hangars, shelters, and the
## airfield lighting (edge, centreline, threshold, approach, PAPI, taxiway).

const RUNWAY_LIFT := 0.1
const PAVE_LIFT := 0.06
const SHOULDER := 7.5
const TAXI_OFFSET := 180.0
const TAXI_W := 23.0

var layout: WorldLayout
var terrain: WorldTerrain
var main: GeoBatch
var airports: Array[Dictionary] = []
## Light sprites: {"pos": Vector3, "color": Color, "size": float, "papi": float}
var lights: Array[Dictionary] = []
var rng := RandomNumberGenerator.new()


func _init(p_layout: WorldLayout, p_terrain: WorldTerrain, p_main: GeoBatch) -> void:
	layout = p_layout
	terrain = p_terrain
	main = p_main
	rng.seed = 991
	for d in WorldLayout.AIRPORT_DEFS:
		airports.append({
			"name": d.name, "code": d.code, "position": Vector3(d.x, d.elevation, d.z),
			"heading_deg": d.heading, "length": d.length, "width": d.width, "elevation": d.elevation,
			"military": d.military,
		})


## Runway frame: origin at runway centre on the surface, -Z along the runway heading, +X to the right.
static func frame(a: Dictionary) -> Transform3D:
	return Transform3D(Basis(Vector3.UP, -deg_to_rad(a.heading_deg)), a.position)


func build(parent: Node3D) -> void:
	var shader: Shader = load("res://shaders/runway.gdshader")
	for a in airports:
		var node := Node3D.new()
		node.name = String(a.code)
		parent.add_child(node)
		var f := frame(a)
		var L: float = a.length
		var W: float = a.width
		var hd := int(round(a.heading_deg / 10.0))
		var n1 := 36 if hd == 0 else hd
		var n2 := posmod(n1 + 18 - 1, 36) + 1
		var mat_rwy := _mat(shader, 0, L, W, n1, n2)
		var mat_taxi := _mat(shader, 1, 1.0, TAXI_W, 0, 0)
		var mat_apron := _mat(shader, 2, 1.0, 1.0, 0, 0)
		# Runway with shoulders, along = distance from the start threshold.
		_strip(node, f, Vector3(0, RUNWAY_LIFT, L * 0.5), Vector3(0, RUNWAY_LIFT, -L * 0.5), W + SHOULDER * 2.0, mat_rwy, L)
		# Parallel taxiway and connectors.
		var tx := TAXI_OFFSET
		_strip(node, f, Vector3(tx, PAVE_LIFT, L * 0.5 + 30.0), Vector3(tx, PAVE_LIFT, -L * 0.5 - 30.0), TAXI_W, mat_taxi, L + 60.0)
		for along in [L * 0.5 - 10.0, -L * 0.5 + 10.0, L * 0.18, -L * 0.22]:
			_strip(node, f, Vector3(W * 0.5, PAVE_LIFT, along), Vector3(tx + TAXI_W * 0.5, PAVE_LIFT, along), TAXI_W, mat_taxi, tx)
		# Apron.
		var apron_len := minf(1100.0, L * 0.4)
		_strip(node, f, Vector3(tx + TAXI_W * 0.5 + 95.0, PAVE_LIFT, apron_len * 0.5), Vector3(tx + TAXI_W * 0.5 + 95.0, PAVE_LIFT, -apron_len * 0.5), 190.0, mat_apron, apron_len)
		var elev: float = a.elevation
		var apron_back := tx + TAXI_W * 0.5 + 190.0
		if a.military:
			_military(f, L, apron_back, elev)
		else:
			_civil(f, L, apron_back, apron_len, elev)
		_tower(f, Vector3(apron_back + 40.0, 0.0, apron_len * 0.5 + 120.0), elev)
		_lights(a, f, L, W)


func _mat(shader: Shader, mode: int, length: float, width: float, n1: int, n2: int) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = shader
	m.set_shader_parameter("mode", mode)
	m.set_shader_parameter("rwy_length", length)
	m.set_shader_parameter("width", width)
	m.set_shader_parameter("number_a", n1)
	m.set_shader_parameter("number_b", n2)
	return m


## Flat paved strip from a to b (runway-frame points) of given width; UV = (across m, along m from a).
func _strip(parent: Node3D, f: Transform3D, a: Vector3, b: Vector3, width: float, mat: Material, length: float) -> void:
	var dir := (b - a)
	var seg_len := dir.length()
	dir /= seg_len
	var side := Vector3(-dir.z, 0.0, dir.x) * (width * 0.5)
	var segs := maxi(1, int(seg_len / 100.0))
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var normals := PackedVector3Array()
	var idx := PackedInt32Array()
	for k in segs + 1:
		var t := float(k) / segs
		var p := a + (b - a) * t
		var along := seg_len * t * (length / seg_len)
		verts.append(f * (p - side))
		verts.append(f * (p + side))
		uvs.append(Vector2(-width * 0.5, along))
		uvs.append(Vector2(width * 0.5, along))
		normals.append(Vector3.UP)
		normals.append(Vector3.UP)
	for k in segs:
		var i := k * 2
		var p0 := verts[i]
		var p1 := verts[i + 1]
		var p2 := verts[i + 3]
		if (p1 - p0).cross(p2 - p0).dot(Vector3.UP) > 0.0:
			idx.append_array([i, i + 3, i + 1, i, i + 2, i + 3])
		else:
			idx.append_array([i, i + 1, i + 3, i, i + 3, i + 2])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)


func _box(f: Transform3D, local_center: Vector3, size: Vector3, style: int, col: Color, elev: float) -> void:
	var xf := f * Transform3D(Basis.IDENTITY, local_center)
	xf.origin.y = elev + local_center.y
	main.add_box(xf, size, Vector2(style, rng.randf() * 100.0), col, elev)


func _civil(f: Transform3D, L: float, apron_back: float, apron_len: float, elev: float) -> void:
	# Terminal: long glass hall with a raised roof block, and a pier.
	var depth := 60.0
	var tlen := apron_len * 0.8
	_box(f, Vector3(apron_back + depth * 0.5 + 10.0, 7.0, 0.0), Vector3(depth, 17.0, tlen), 9, Color(0.8, 0.95, 1.0), elev)
	_box(f, Vector3(apron_back + depth * 0.5 + 10.0, 17.0, 0.0), Vector3(depth * 0.7, 4.0, tlen * 0.9), 8, Color(0.75, 0.76, 0.78), elev)
	_box(f, Vector3(apron_back - 30.0, 4.5, 0.0), Vector3(50.0, 9.0, 14.0), 9, Color(0.8, 0.95, 1.0), elev)
	# Car park and service buildings behind.
	_box(f, Vector3(apron_back + depth + 45.0, 6.0, -tlen * 0.25), Vector3(50.0, 12.0, tlen * 0.4), 5, Color(0.55, 0.54, 0.52), elev)
	# Maintenance hangars past the apron.
	for k in 3:
		var z := -apron_len * 0.5 - 120.0 - k * 95.0
		_box(f, Vector3(apron_back - 70.0, 11.0, z), Vector3(70.0, 22.0, 80.0), 6, Color(0.62, 0.64, 0.66), elev)
	# Fuel tanks.
	for k in 3:
		var c := f * Vector3(apron_back + 60.0 + k * 22.0, 0.0, apron_len * 0.5 + 60.0)
		main.add_prism(Vector2(c.x, c.z), 8.0, 12, elev - 1.0, elev + 12.0, Vector2(8, k), Color(0.8, 0.8, 0.78), elev)


func _military(f: Transform3D, L: float, apron_back: float, elev: float) -> void:
	# Hardened aircraft shelters along a taxi lane.
	for k in 8:
		var z := -L * 0.15 - k * 70.0
		var xf := f * Transform3D(Basis(Vector3.UP, -PI * 0.5), Vector3(apron_back + 40.0, 0.0, z))
		xf.origin.y = elev
		main.add_arch(xf, 13.0, 36.0, 8, Vector2(5, k), Color(0.45, 0.44, 0.40), elev)
	# Large hangars, operations block and barracks.
	for k in 3:
		_box(f, Vector3(apron_back - 60.0, 12.0, L * 0.12 + k * 100.0), Vector3(80.0, 24.0, 85.0), 6, Color(0.42, 0.45, 0.42), elev)
	_box(f, Vector3(apron_back + 90.0, 8.0, L * 0.1), Vector3(40.0, 16.0, 120.0), 1, Color(0.48, 0.47, 0.44), elev)
	for k in 4:
		_box(f, Vector3(apron_back + 150.0, 6.0, -k * 70.0), Vector3(20.0, 12.0, 55.0), 2, Color(0.45, 0.33, 0.25), elev)


func _tower(f: Transform3D, local: Vector3, elev: float) -> void:
	_box(f, Vector3(local.x, 20.0, local.z), Vector3(8.0, 40.0, 8.0), 5, Color(0.62, 0.6, 0.57), elev)
	_box(f, Vector3(local.x, 43.0, local.z), Vector3(14.0, 6.0, 14.0), 10, Color(0.8, 0.9, 0.9), elev)
	_box(f, Vector3(local.x, 46.5, local.z), Vector3(15.0, 1.0, 15.0), 8, Color(0.4, 0.4, 0.42), elev)


func _add_light(p: Vector3, col: Color, size: float, papi := 0.0) -> void:
	lights.append({"pos": p, "color": col, "size": size, "papi": papi})


func _lights(a: Dictionary, f: Transform3D, L: float, W: float) -> void:
	var white := Color(1.0, 0.95, 0.85)
	var yellow := Color(1.0, 0.75, 0.3)
	var green := Color(0.3, 1.0, 0.45)
	var red := Color(1.0, 0.15, 0.1)
	var blue := Color(0.25, 0.4, 1.0)
	var y := RUNWAY_LIFT + 0.4
	# Edge lights (yellow in the last 600 m from each end direction is approximated as caution zone).
	var n := int(L / 60.0)
	for k in n + 1:
		var z := L * 0.5 - k * L / n
		var col := yellow if absf(z) > L * 0.5 - 600.0 and z < 0.0 else white
		for side in [-1.0, 1.0]:
			_add_light(f * Vector3(side * (W * 0.5 + 1.5), y, z), col, 0.9)
	# Centreline lights.
	for k in int(L / 30.0) + 1:
		var z := L * 0.5 - k * 30.0
		_add_light(f * Vector3(0.0, RUNWAY_LIFT + 0.05, z), white, 0.6)
	# Threshold bars and approach lighting at both ends.
	for end in [1.0, -1.0]:
		var zt: float = end * L * 0.5
		for k in int(W / 3.0) + 1:
			_add_light(f * Vector3(-W * 0.5 + k * 3.0, y, zt + end * 1.0), green, 0.9)
			_add_light(f * Vector3(-W * 0.5 + k * 3.0, y, zt - end * 1.0), red, 0.7)
		for k in range(1, 31):
			var z: float = zt + end * k * 30.0
			var bar := 5 if k != 10 else 21
			for b in bar:
				var x := (b - (bar - 1) * 0.5) * (1.0 if bar == 5 else 1.5)
				var p := f * Vector3(x, 0.0, z)
				p.y = maxf(terrain.height_at(p.x, p.z), 0.0) + 1.2
				_add_light(p, white, 1.0)
		# PAPI: four units left of the runway, 300 m past the threshold, inner unit highest angle.
		var angles := [3.5, 3.17, 2.83, 2.5]
		for k in 4:
			var x: float = end * -(W * 0.5 + 15.0 + k * 9.0)
			_add_light(f * Vector3(x, y + 0.4, zt - end * 300.0), white, 1.3, angles[k])
	# Taxiway edge lights.
	for k in int((L + 60.0) / 50.0) + 1:
		var z := L * 0.5 + 30.0 - k * 50.0
		for side in [-1.0, 1.0]:
			_add_light(f * Vector3(TAXI_OFFSET + side * (TAXI_W * 0.5 + 1.0), PAVE_LIFT + 0.4, z), blue, 0.6)


## On the centreline 120 m past the threshold, facing down the runway; origin y = runway surface.
func runway_start_transform(index: int, reverse: bool) -> Transform3D:
	var a := airports[index]
	var f := frame(a)
	var end := -1.0 if reverse else 1.0
	var basis := f.basis if not reverse else f.basis.rotated(Vector3.UP, PI)
	var origin := f * Vector3(0.0, 0.0, end * (a.length * 0.5 - 120.0))
	origin.y = a.elevation
	return Transform3D(basis, origin)


func approach_transform(index: int, distance: float, reverse: bool) -> Transform3D:
	var a := airports[index]
	var f := frame(a)
	var end := -1.0 if reverse else 1.0
	var basis := f.basis if not reverse else f.basis.rotated(Vector3.UP, PI)
	var threshold := f * Vector3(0.0, 0.0, end * a.length * 0.5)
	var fwd := -basis.z
	var origin := threshold - fwd * distance
	origin.y = a.elevation + 15.0 + distance * tan(deg_to_rad(3.0))
	return Transform3D(basis, origin)
