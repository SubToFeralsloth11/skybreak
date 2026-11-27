class_name GeoBatch
extends RefCounted
## Accumulates boxes and prisms into spatially chunked merged meshes (building shader vertex format),
## adding a matching collision shape to one StaticBody3D and registering world AABBs.
## Vertex format: UV = (metres along facade, metres above building ground), UV2 = (style, seed), COLOR = tint.

var chunk_size: float
var body: StaticBody3D
var aabbs: Array[AABB] = []
var _chunks := {}


func _init(p_body: StaticBody3D, p_chunk_size := 1000.0) -> void:
	body = p_body
	chunk_size = p_chunk_size


func _arrays(p: Vector3) -> Dictionary:
	var key := Vector2i(floori(p.x / chunk_size), floori(p.z / chunk_size))
	var a: Dictionary = _chunks.get(key, {})
	if a.is_empty():
		a = {"v": PackedVector3Array(), "n": PackedVector3Array(), "uv": PackedVector2Array(),
			"uv2": PackedVector2Array(), "c": PackedColorArray(), "i": PackedInt32Array()}
		_chunks[key] = a
	return a


## Quad p0..p3 (any winding), facing `n`.
func _quad(a: Dictionary, p: Array, uv: Array, n: Vector3, style: Vector2, col: Color) -> void:
	var v: PackedVector3Array = a.v
	var base := v.size()
	for k in 4:
		v.append(p[k])
		a.n.append(n)
		a.uv.append(uv[k])
		a.uv2.append(style)
		a.c.append(col)
	var idx: PackedInt32Array = a.i
	# Godot front faces are clockwise: flip when the counter-clockwise normal points along n.
	if (p[1] - p[0]).cross(p[2] - p[0]).dot(n) > 0.0:
		idx.append_array([base, base + 2, base + 1, base, base + 3, base + 2])
	else:
		idx.append_array([base, base + 1, base + 2, base, base + 2, base + 3])


func _add_collision(shape: Shape3D, xf: Transform3D) -> void:
	if body == null:
		return
	var owner_id := body.create_shape_owner(body)
	body.shape_owner_add_shape(owner_id, shape)
	body.shape_owner_set_transform(owner_id, xf)


## Oriented box. `ground_y` anchors the facade v coordinate (floors line up across setbacks).
func add_box(xf: Transform3D, size: Vector3, style: Vector2, col: Color, ground_y: float,
		collide := true, register := true, bottom := false) -> void:
	var h := size * 0.5
	var c: Array[Vector3] = []
	for k in 8:
		c.append(xf * Vector3(h.x if k & 1 else -h.x, h.y if k & 2 else -h.y, h.z if k & 4 else -h.z))
	var a := _arrays(xf.origin)
	var bx := xf.basis.x.normalized()
	var by := xf.basis.y.normalized()
	var bz := xf.basis.z.normalized()
	var y0 := c[0].y - ground_y
	# Sides: v follows world height so tilted boxes still get sensible coordinates.
	_side(a, c[0], c[4], c[6], c[2], -bx, size.z, style, col, ground_y)  # -X
	_side(a, c[5], c[1], c[3], c[7], bx, size.z, style, col, ground_y)   # +X
	_side(a, c[1], c[0], c[2], c[3], -bz, size.x, style, col, ground_y)  # -Z
	_side(a, c[4], c[5], c[7], c[6], bz, size.x, style, col, ground_y)   # +Z
	_quad(a, [c[2], c[3], c[7], c[6]], [Vector2(c[2].x, c[2].z), Vector2(c[3].x, c[3].z), Vector2(c[7].x, c[7].z), Vector2(c[6].x, c[6].z)], by, style, col)
	if bottom:
		_quad(a, [c[0], c[1], c[5], c[4]], [Vector2(0, y0), Vector2(size.x, y0), Vector2(size.x, y0), Vector2(0, y0)], -by, style, col)
	if collide:
		var shape := BoxShape3D.new()
		shape.size = size
		_add_collision(shape, xf)
	if register:
		aabbs.append(xf * AABB(-h, size))


func _side(a: Dictionary, p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, n: Vector3, w: float,
		style: Vector2, col: Color, ground_y: float) -> void:
	_quad(a, [p0, p1, p2, p3], [Vector2(0.0, p0.y - ground_y), Vector2(w, p1.y - ground_y),
		Vector2(w, p2.y - ground_y), Vector2(0.0, p3.y - ground_y)], n, style, col)


## Axis-aligned box from ground level `y0` to `y1` (convenience for buildings).
func add_block(center_xz: Vector2, size_xz: Vector2, y0: float, y1: float, style: Vector2, col: Color,
		ground_y: float, collide := true, register := true) -> void:
	var xf := Transform3D(Basis.IDENTITY, Vector3(center_xz.x, (y0 + y1) * 0.5, center_xz.y))
	add_box(xf, Vector3(size_xz.x, y1 - y0, size_xz.y), style, col, ground_y, collide, register)


## Vertical regular prism (octagonal towers, tanks). Collision is the exact convex hull.
func add_prism(center_xz: Vector2, radius: float, sides: int, y0: float, y1: float, style: Vector2,
		col: Color, ground_y: float, collide := true, register := true) -> void:
	var a := _arrays(Vector3(center_xz.x, y0, center_xz.y))
	var ring: Array[Vector2] = []
	for k in sides:
		var ang := TAU * (k + 0.5) / sides
		ring.append(center_xz + Vector2(cos(ang), sin(ang)) * radius)
	var edge := ring[0].distance_to(ring[1])
	var top := PackedVector3Array()
	for k in sides:
		var p := ring[k]
		var q := ring[(k + 1) % sides]
		var mid := (p + q) * 0.5 - center_xz
		var n := Vector3(mid.x, 0.0, mid.y).normalized()
		_side(a, Vector3(p.x, y0, p.y), Vector3(q.x, y0, q.y), Vector3(q.x, y1, q.y), Vector3(p.x, y1, p.y), n, edge, style, col, ground_y)
		top.append(Vector3(p.x, y1, p.y))
	# Roof fan.
	var v: PackedVector3Array = a.v
	var base := v.size()
	var centre := Vector3(center_xz.x, y1, center_xz.y)
	v.append(centre)
	a.n.append(Vector3.UP)
	a.uv.append(center_xz)
	a.uv2.append(style)
	a.c.append(col)
	for p in top:
		v.append(p)
		a.n.append(Vector3.UP)
		a.uv.append(Vector2(p.x, p.z))
		a.uv2.append(style)
		a.c.append(col)
	for k in sides:
		var i1 := base + 1 + k
		var i2 := base + 1 + (k + 1) % sides
		var cw := (v[i1] - centre).cross(v[i2] - centre).dot(Vector3.UP) < 0.0
		a.i.append_array([base, i1, i2] if cw else [base, i2, i1])
	var pts := PackedVector3Array()
	for p in ring:
		pts.append(Vector3(p.x, y0, p.y))
		pts.append(Vector3(p.x, y1, p.y))
	if collide:
		var shape := ConvexPolygonShape3D.new()
		shape.points = pts
		_add_collision(shape, Transform3D.IDENTITY)
	if register:
		aabbs.append(AABB(Vector3(center_xz.x - radius, y0, center_xz.y - radius), Vector3(radius * 2.0, y1 - y0, radius * 2.0)))


## Arched shelter / hangar roof: half-cylinder (segments) of `radius` along local Z with length `length`,
## placed by xf (origin at floor centre). Walls at the ends. Collision is a convex hull.
func add_arch(xf: Transform3D, radius: float, length: float, segments: int, style: Vector2, col: Color,
		ground_y: float) -> void:
	var a := _arrays(xf.origin)
	var prof: Array[Vector3] = []
	for k in segments + 1:
		var ang := PI * k / segments
		prof.append(Vector3(cos(ang) * radius, sin(ang) * radius * 0.8, 0.0))
	var hl := length * 0.5
	var pts := PackedVector3Array()
	for k in segments:
		var p := prof[k]
		var q := prof[k + 1]
		var mid := (p + q) * 0.5
		var n := xf.basis * Vector3(mid.x, mid.y / 0.64, 0.0).normalized()
		var arc := p.distance_to(q)
		_quad(a, [xf * (p + Vector3(0, 0, -hl)), xf * (q + Vector3(0, 0, -hl)), xf * (q + Vector3(0, 0, hl)), xf * (p + Vector3(0, 0, hl))],
			[Vector2(k * arc, 0.0), Vector2((k + 1) * arc, 0.0), Vector2((k + 1) * arc, length), Vector2(k * arc, length)], n.normalized(), style, col)
	for side in [-1.0, 1.0]:
		var z: float = hl * side
		var n: Vector3 = (xf.basis * Vector3(0, 0, side)).normalized()
		var centre := xf * Vector3(0, 0, z)
		for k in segments:
			var p := xf * (prof[k] + Vector3(0, 0, z))
			var q := xf * (prof[k + 1] + Vector3(0, 0, z))
			var v: PackedVector3Array = a.v
			var base := v.size()
			for pt in [centre, p, q]:
				v.append(pt)
				a.n.append(n)
				a.uv.append(Vector2(pt.dot(xf.basis.x.normalized()), pt.y - ground_y))
				a.uv2.append(style)
				a.c.append(col)
			var cw := (p - centre).cross(q - centre).dot(n) < 0.0
			a.i.append_array([base, base + 1, base + 2] if cw else [base, base + 2, base + 1])
	for p in prof:
		pts.append(p + Vector3(0, 0, -hl))
		pts.append(p + Vector3(0, 0, hl))
	var shape := ConvexPolygonShape3D.new()
	shape.points = pts
	_add_collision(shape, xf)
	var aabb := AABB(Vector3(-radius, 0, -hl), Vector3(radius * 2.0, radius * 0.8, length))
	aabbs.append(xf * aabb)


## Builds one MeshInstance3D per chunk under `parent`.
func build(parent: Node3D, material: Material, vis_end := 0.0, shadows := true) -> void:
	for key in _chunks:
		var a: Dictionary = _chunks[key]
		if a.i.is_empty():
			continue
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = a.v
		arrays[Mesh.ARRAY_NORMAL] = a.n
		arrays[Mesh.ARRAY_TEX_UV] = a.uv
		arrays[Mesh.ARRAY_TEX_UV2] = a.uv2
		arrays[Mesh.ARRAY_COLOR] = a.c
		arrays[Mesh.ARRAY_INDEX] = a.i
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		mi.material_override = material
		mi.visibility_range_end = vis_end
		if vis_end > 0.0:
			mi.visibility_range_end_margin = vis_end * 0.1
			mi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		parent.add_child(mi)
	_chunks.clear()
