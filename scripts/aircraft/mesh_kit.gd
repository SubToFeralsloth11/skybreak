class_name MeshKit
extends RefCounted
## Procedural mesh helpers for aircraft. Every mesh is built directly in body coordinates.

const AIRFOIL_T := [0.0, 0.012, 0.05, 0.12, 0.22, 0.35, 0.5, 0.65, 0.8, 0.92, 1.0]


## Closed ring grid -> smooth mesh. rings[i] = PackedVector3Array (same count, closed loop).
## Normals point away from each ring's centroid. Optional end caps.
static func grid_mesh(rings: Array, cap_start := true, cap_end := true, uv_scale := 1.0) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var n_rings := rings.size()
	var n := (rings[0] as PackedVector3Array).size()
	var centers: Array[Vector3] = []
	for r in rings:
		var c := Vector3.ZERO
		for p in r:
			c += p
		centers.append(c / float(n))
	# Per-vertex normals from the grid.
	var normals: Array = []
	for i in n_rings:
		var ring: PackedVector3Array = rings[i]
		var rn := PackedVector3Array()
		rn.resize(n)
		for j in n:
			var a: Vector3 = rings[mini(i + 1, n_rings - 1)][j] - rings[maxi(i - 1, 0)][j]
			var b: Vector3 = ring[(j + 1) % n] - ring[(j - 1 + n) % n]
			var nrm := a.cross(b)
			if nrm.length_squared() < 1e-12:
				nrm = ring[j] - centers[i]
			nrm = nrm.normalized()
			if nrm.dot(ring[j] - centers[i]) < 0.0:
				nrm = -nrm
			rn[j] = nrm
		normals.append(rn)
	for i in n_rings - 1:
		for j in n:
			var j2 := (j + 1) % n
			var quad := [[i, j], [i + 1, j], [i + 1, j2], [i, j2]]
			var pts: Array[Vector3] = []
			for q in quad:
				pts.append(rings[q[0]][q[1]])
			# Orient triangle so its face normal agrees with vertex normals.
			var face := (pts[1] - pts[0]).cross(pts[2] - pts[0])
			var avg_n: Vector3 = normals[i][j] + normals[i + 1][j2]
			var order := [0, 1, 2, 0, 2, 3] if face.dot(avg_n) < 0.0 else [0, 2, 1, 0, 3, 2]
			for o in order:
				var q2: Array = quad[o]
				st.set_normal(normals[q2[0]][q2[1]])
				st.set_uv(Vector2(float(q2[1]) / n, float(q2[0]) / n_rings) * uv_scale)
				st.add_vertex(rings[q2[0]][q2[1]])
	if cap_start:
		_cap(st, rings[0], centers[0], (centers[0] - centers[mini(1, n_rings - 1)]).normalized())
	if cap_end:
		_cap(st, rings[n_rings - 1], centers[n_rings - 1], (centers[n_rings - 1] - centers[maxi(n_rings - 2, 0)]).normalized())
	return st.commit()


static func _cap(st: SurfaceTool, ring: PackedVector3Array, center: Vector3, out_dir: Vector3) -> void:
	if out_dir.length_squared() < 1e-6:
		return
	var n := ring.size()
	for j in n:
		var a := ring[j]
		var b := ring[(j + 1) % n]
		var face := (a - center).cross(b - center)
		var tri := [center, a, b] if face.dot(out_dir) < 0.0 else [center, b, a]
		for p in tri:
			st.set_normal(out_dir)
			st.set_uv(Vector2(0.5, 0.5))
			st.add_vertex(p)


## Fuselage-style loft. sections: Array of [z, center_y, half_width, half_height, (optional) bottom_flat 0..1, (optional) center_x]
static func loft(sections: Array, segments := 24, cap_start := true, cap_end := true) -> ArrayMesh:
	var rings: Array = []
	for s in sections:
		var z: float = s[0]
		var cy: float = s[1]
		var rx: float = maxf(s[2], 0.002)
		var ry: float = maxf(s[3], 0.002)
		var flat: float = s[4] if s.size() > 4 else 0.0
		var cx: float = s[5] if s.size() > 5 else 0.0
		var ring := PackedVector3Array()
		for j in segments:
			var a := TAU * float(j) / segments
			var x := sin(a)
			var y := cos(a)
			# Superellipse-ish squareness for flatter bellies/boxy sections.
			var sx := signf(x) * pow(absf(x), 1.0 - flat * 0.6)
			var sy := signf(y) * pow(absf(y), 1.0 - flat * 0.6)
			if y < 0.0 and flat > 0.0:
				sy = lerpf(sy, maxf(sy, -0.82), flat)
			ring.append(Vector3(cx + sx * rx, cy + sy * ry, z))
		rings.append(ring)
	return grid_mesh(rings, cap_start, cap_end)


static func _airfoil_ring(le: Vector3, chord: float, thick: float, chord_dir: Vector3, thick_dir: Vector3) -> PackedVector3Array:
	var ring := PackedVector3Array()
	var count := AIRFOIL_T.size()
	# Upper surface TE -> LE, lower surface LE -> TE (skip duplicate endpoints).
	for idx in range(count - 1, -1, -1):
		var t: float = AIRFOIL_T[idx]
		ring.append(le + chord_dir * (t * chord) + thick_dir * (_naca_half(t) * thick * chord))
	for idx in range(1, count - 1):
		var t2: float = AIRFOIL_T[idx]
		ring.append(le + chord_dir * (t2 * chord) - thick_dir * (_naca_half(t2) * thick * chord))
	return ring


static func _naca_half(t: float) -> float:
	return 5.0 * (0.2969 * sqrt(t) - 0.126 * t - 0.3516 * t * t + 0.2843 * t * t * t - 0.1036 * t * t * t * t) + 0.0025


## Tapered wing panel. le_root/le_tip are leading-edge points; chord runs +Z (aft).
## thick_dir: Vector3.UP for horizontal surfaces, Vector3.RIGHT for fins.
static func wing(le_root: Vector3, chord_root: float, le_tip: Vector3, chord_tip: float, thickness: float,
		thick_dir := Vector3.UP, stations := 4) -> ArrayMesh:
	var rings: Array = []
	for i in stations:
		var f := float(i) / float(stations - 1)
		var le := le_root.lerp(le_tip, f)
		var chord := lerpf(chord_root, chord_tip, f)
		var th := lerpf(thickness, thickness * 0.75, f)
		rings.append(_airfoil_ring(le, chord, th, Vector3(0, 0, 1), thick_dir))
	return grid_mesh(rings)


static func cylinder_between(a: Vector3, b: Vector3, r_a: float, r_b: float, segments := 12) -> ArrayMesh:
	var axis := (b - a).normalized()
	var side := axis.cross(Vector3.UP)
	if side.length_squared() < 1e-4:
		side = axis.cross(Vector3.RIGHT)
	side = side.normalized()
	var up := side.cross(axis).normalized()
	var rings: Array = []
	for k in 2:
		var c := a if k == 0 else b
		var r := r_a if k == 0 else r_b
		var ring := PackedVector3Array()
		for j in segments:
			var ang := TAU * float(j) / segments
			ring.append(c + (side * cos(ang) + up * sin(ang)) * r)
		rings.append(ring)
	return grid_mesh(rings)


static func box(center: Vector3, size: Vector3) -> ArrayMesh:
	var bm := BoxMesh.new()
	bm.size = size
	var arr := bm.get_mesh_arrays()
	var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	for i in verts.size():
		verts[i] += center
	arr[Mesh.ARRAY_VERTEX] = verts
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _deindex(arr))
	return m


static func sphere(center: Vector3, radius: Vector3, segments := 16, rings := 10) -> ArrayMesh:
	var sm := SphereMesh.new()
	sm.radius = 1.0
	sm.height = 2.0
	sm.radial_segments = segments
	sm.rings = rings
	var arr := sm.get_mesh_arrays()
	var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var norms: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
	for i in verts.size():
		verts[i] = center + verts[i] * radius
		norms[i] = (norms[i] / radius).normalized()
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = norms
	arr[Mesh.ARRAY_TANGENT] = null
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _deindex(arr))
	return m


static func _deindex(arr: Array) -> Array:
	if arr[Mesh.ARRAY_INDEX] == null:
		return arr
	var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
	var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var nm: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
	var uv: PackedVector2Array = arr[Mesh.ARRAY_TEX_UV] if arr[Mesh.ARRAY_TEX_UV] != null else PackedVector2Array()
	var out := []
	out.resize(Mesh.ARRAY_MAX)
	var ov := PackedVector3Array()
	var on := PackedVector3Array()
	var ou := PackedVector2Array()
	for i in idx:
		ov.append(v[i])
		on.append(nm[i])
		ou.append(uv[i] if uv.size() > i else Vector2.ZERO)
	out[Mesh.ARRAY_VERTEX] = ov
	out[Mesh.ARRAY_NORMAL] = on
	out[Mesh.ARRAY_TEX_UV] = ou
	return out


## Merge several meshes (same material) into one ArrayMesh surface.
static func merge(meshes: Array) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for m in meshes:
		if m == null:
			continue
		for s in (m as Mesh).get_surface_count():
			st.append_from(m, s, Transform3D.IDENTITY)
	return st.commit()


static func mirror_x(mesh: ArrayMesh) -> ArrayMesh:
	var out := ArrayMesh.new()
	for s in mesh.get_surface_count():
		var arr := mesh.surface_get_arrays(s)
		var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var norms: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
		for i in verts.size():
			verts[i].x = -verts[i].x
			norms[i].x = -norms[i].x
		# Flip winding.
		var idx = arr[Mesh.ARRAY_INDEX]
		if idx == null:
			for i in range(0, verts.size(), 3):
				var tv := verts[i + 1]
				verts[i + 1] = verts[i + 2]
				verts[i + 2] = tv
				var tn := norms[i + 1]
				norms[i + 1] = norms[i + 2]
				norms[i + 2] = tn
				if arr[Mesh.ARRAY_TEX_UV] != null:
					var uvs: PackedVector2Array = arr[Mesh.ARRAY_TEX_UV]
					var tu := uvs[i + 1]
					uvs[i + 1] = uvs[i + 2]
					uvs[i + 2] = tu
					arr[Mesh.ARRAY_TEX_UV] = uvs
		else:
			var ia: PackedInt32Array = idx
			for i in range(0, ia.size(), 3):
				var t := ia[i + 1]
				ia[i + 1] = ia[i + 2]
				ia[i + 2] = t
			arr[Mesh.ARRAY_INDEX] = ia
		arr[Mesh.ARRAY_VERTEX] = verts
		arr[Mesh.ARRAY_NORMAL] = norms
		arr[Mesh.ARRAY_TANGENT] = null
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return out
