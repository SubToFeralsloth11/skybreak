class_name WorldForest
extends RefCounted
## Low-poly conifers and broadleaf trees as MultiMeshes, one pair per 2.5 km terrain chunk with a visibility
## range. Placement follows the control map's forest channel (the terrain shader darkens the same areas so
## forests stay visible beyond the tree range), plus scattered suburban and park trees.

const DENSITY := 1.7          # trees per control cell at full forest density
const VIS_RANGE := 6500.0
const CHUNK := 2500.0

var layout: WorldLayout
var terrain: WorldTerrain
var rng := RandomNumberGenerator.new()
var tree_count := 0
var _buckets := {}   # Vector3i(cx, cz, kind) -> PackedFloat32Array


func _init(p_layout: WorldLayout, p_terrain: WorldTerrain) -> void:
	layout = p_layout
	terrain = p_terrain
	rng.seed = 4242


func build(parent: Node3D, extra_trees: Array[Vector3], blockers: Callable) -> void:
	var m := (WorldLayout.SAMPLES - 1) / WorldLayout.CTL_STEP + 1
	var cell := WorldLayout.CELL * WorldLayout.CTL_STEP
	var ctl := terrain.control
	for j in m:
		for i in m:
			var k := (j * m + i) * 4
			var forest := ctl[k] / 255.0
			var urban := ctl[k + 1] / 255.0
			var count := 0
			if forest > 0.08:
				count = int(forest * DENSITY + rng.randf())
			elif urban > 0.2 and urban < 0.7 and rng.randf() < 0.5:
				count = 1
			for t in count:
				var x := -WorldLayout.HALF + (i + rng.randf_range(-0.5, 0.5)) * cell
				var z := -WorldLayout.HALF + (j + rng.randf_range(-0.5, 0.5)) * cell
				var h := terrain.height_at(x, z)
				if h < 3.0:
					continue
				if forest <= 0.08:
					if not blockers.call(Vector3(x, h, z)):
						continue
				var conifer := h > 450.0 + rng.randf_range(-250.0, 250.0) or rng.randf() < 0.2
				_add(x, h, z, conifer, forest <= 0.08)
	for p in extra_trees:
		_add(p.x, p.y, p.z, false, true)
	_flush(parent)


func _add(x: float, y: float, z: float, conifer: bool, urban: bool) -> void:
	var s := rng.randf_range(0.7, 1.35) * (0.8 if urban else 1.0)
	var rot := rng.randf() * TAU
	var c := cos(rot) * s
	var sn := sin(rot) * s
	var key := Vector3i(floori(x / CHUNK), floori(z / CHUNK), 1 if conifer else 0)
	var buf: PackedFloat32Array = _buckets.get(key, PackedFloat32Array())
	var tint: Color
	if conifer:
		tint = Color(0.035, 0.07, 0.035).lerp(Color(0.05, 0.085, 0.04), rng.randf())
	else:
		tint = Color(0.06, 0.1, 0.03).lerp(Color(0.1, 0.12, 0.035), rng.randf())
	# Transform rows (basis rows + origin) then custom data.
	buf.append_array([c, 0.0, sn, x, 0.0, s, 0.0, y - 0.3, -sn, 0.0, c, z, tint.r, tint.g, tint.b, rng.randf()])
	_buckets[key] = buf
	tree_count += 1


func _flush(parent: Node3D) -> void:
	var meshes := [_broadleaf_mesh(), _conifer_mesh()]
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/tree.gdshader")
	for key: Vector3i in _buckets:
		var buf: PackedFloat32Array = _buckets[key]
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_custom_data = true
		mm.mesh = meshes[key.z]
		mm.instance_count = buf.size() / 16
		mm.buffer = buf
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.material_override = mat
		mmi.position = Vector3.ZERO
		mmi.visibility_range_end = VIS_RANGE
		mmi.visibility_range_end_margin = 800.0
		mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
		parent.add_child(mmi)
	_buckets.clear()


# --- meshes -------------------------------------------------------------------------------

func _append(dst: Dictionary, arrays: Array, xf: Transform3D, foliage: float, round_center := Vector3.INF) -> void:
	var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var n: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var base: int = dst.v.size()
	for k in v.size():
		var p := xf * v[k]
		dst.v.append(p)
		var nn := (xf.basis * n[k]).normalized()
		if round_center != Vector3.INF:
			nn = (nn + (p - round_center).normalized() * 1.5 + Vector3.UP * 0.3).normalized()
		dst.n.append(nn)
		dst.uv.append(Vector2(foliage, 0.0))
	for k in idx:
		dst.i.append(base + k)


func _finish(dst: Dictionary) -> ArrayMesh:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = dst.v
	arrays[Mesh.ARRAY_NORMAL] = dst.n
	arrays[Mesh.ARRAY_TEX_UV] = dst.uv
	arrays[Mesh.ARRAY_INDEX] = dst.i
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func _new_dst() -> Dictionary:
	return {"v": PackedVector3Array(), "n": PackedVector3Array(), "uv": PackedVector2Array(), "i": PackedInt32Array()}


func _cyl(top: float, bottom: float, height: float, sides: int) -> Array:
	var c := CylinderMesh.new()
	c.top_radius = top
	c.bottom_radius = bottom
	c.height = height
	c.radial_segments = sides
	c.rings = 0
	c.cap_top = top > 0.0
	c.cap_bottom = true
	return c.get_mesh_arrays()


func _conifer_mesh() -> ArrayMesh:
	var d := _new_dst()
	_append(d, _cyl(0.25, 0.4, 4.0, 5), Transform3D(Basis.IDENTITY, Vector3(0, 2.0, 0)), 0.0)
	var tiers := [[3.6, 7.0, 2.5], [2.8, 6.0, 6.0], [1.9, 5.5, 9.5], [1.0, 4.0, 13.0]]
	for t in tiers:
		_append(d, _cyl(0.0, t[0], t[1], 7), Transform3D(Basis.IDENTITY, Vector3(0, t[2] + t[1] * 0.5, 0)), 1.0, Vector3(0, t[2], 0))
	return _finish(d)


func _broadleaf_mesh() -> ArrayMesh:
	var d := _new_dst()
	_append(d, _cyl(0.3, 0.45, 5.0, 5), Transform3D(Basis.IDENTITY, Vector3(0, 2.5, 0)), 0.0)
	var s := SphereMesh.new()
	s.radius = 1.0
	s.height = 2.0
	s.radial_segments = 8
	s.rings = 5
	var arr := s.get_mesh_arrays()
	var blobs := [[Vector3(0, 8.0, 0), Vector3(4.2, 3.6, 4.2)], [Vector3(1.6, 9.8, 0.8), Vector3(2.8, 2.5, 2.8)],
		[Vector3(-1.5, 9.4, -1.0), Vector3(2.9, 2.6, 2.9)], [Vector3(0.2, 6.6, -1.8), Vector3(3.0, 2.4, 3.0)]]
	for b in blobs:
		_append(d, arr, Transform3D(Basis.from_scale(b[1]), b[0]), 1.0, Vector3(0, 7.5, 0))
	return _finish(d)
