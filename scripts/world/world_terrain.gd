class_name WorldTerrain
extends Node3D
## Heightmap terrain: generates (or loads from the user:// cache) the height and control grids,
## draws them as GPU-displaced chunks with two LODs plus a low-res outer ring out to 80 km,
## and adds a HeightMapShape3D whose triangulation matches the visual mesh and height_at().

const CACHE_PATH := "user://skybreak_terrain_v4.bin"
const CACHE_MAGIC := 0x534B5933
const CHUNK_CELLS := 64
const LOD1_STEP := 4
const LOD0_RANGE := 7000.0
const OUTER_CHUNK_CELLS := 32

var layout: WorldLayout
var heights := PackedFloat32Array()        # SAMPLES x SAMPLES, row-major [z][x]
var control := PackedByteArray()           # (SAMPLES/2+1)^2 RGBA8
var outer_heights := PackedFloat32Array()
var outer_control := PackedByteArray()
var height_texture: ImageTexture
var control_texture: ImageTexture
var outer_height_texture: ImageTexture
var outer_control_texture: ImageTexture
var material: ShaderMaterial
var outer_material: ShaderMaterial

var _rows: Array = []
var _rows_mutex := Mutex.new()
var _grid_n := 0
var _grid_origin := 0.0
var _grid_cell := 0.0


func _init(p_layout: WorldLayout) -> void:
	layout = p_layout
	name = "Terrain"


## Fills heights/control (cache or worker threads). Emits progress through `report(fraction)`.
func generate(report: Callable) -> void:
	if _load_cache():
		report.call(1.0)
		return
	heights = await _sample_grid(WorldLayout.SAMPLES, -WorldLayout.HALF, WorldLayout.CELL, report, 0.0, 0.75)
	outer_heights = await _sample_grid(WorldLayout.OUTER_SAMPLES, -WorldLayout.OUTER_HALF, WorldLayout.OUTER_CELL, report, 0.75, 0.85)
	control = _control_grid(heights, WorldLayout.SAMPLES, -WorldLayout.HALF, WorldLayout.CELL, WorldLayout.CTL_STEP)
	report.call(0.95)
	outer_control = _control_grid(outer_heights, WorldLayout.OUTER_SAMPLES, -WorldLayout.OUTER_HALF, WorldLayout.OUTER_CELL, 1)
	_save_cache()
	report.call(1.0)


func _sample_grid(n: int, origin: float, cell: float, report: Callable, f0: float, f1: float) -> PackedFloat32Array:
	_grid_n = n
	_grid_origin = origin
	_grid_cell = cell
	_rows.resize(n)
	var task := WorkerThreadPool.add_group_task(_sample_row, n, -1, true, "terrain rows")
	while not WorkerThreadPool.is_group_task_completed(task):
		report.call(lerpf(f0, f1, float(WorkerThreadPool.get_group_processed_element_count(task)) / n))
		await get_tree().process_frame
	WorkerThreadPool.wait_for_group_task_completion(task)
	var out := PackedFloat32Array()
	out.resize(n * n)
	for j in n:
		var row: PackedFloat32Array = _rows[j]
		for i in n:
			out[j * n + i] = row[i]
	_rows.clear()
	return out


func _sample_row(j: int) -> void:
	var row := PackedFloat32Array()
	row.resize(_grid_n)
	var z := _grid_origin + j * _grid_cell
	for i in _grid_n:
		row[i] = layout.height(_grid_origin + i * _grid_cell, z)
	_rows_mutex.lock()
	_rows[j] = row
	_rows_mutex.unlock()


func _control_grid(src: PackedFloat32Array, n: int, origin: float, cell: float, step: int) -> PackedByteArray:
	var m := (n - 1) / step + 1
	var out := PackedByteArray()
	out.resize(m * m * 4)
	var span := cell * step * 2.0
	for cj in m:
		var j := cj * step
		var jm := maxi(j - step, 0) * n
		var jp := mini(j + step, n - 1) * n
		for ci in m:
			var i := ci * step
			var h := src[j * n + i]
			var dx := src[j * n + mini(i + step, n - 1)] - src[j * n + maxi(i - step, 0)]
			var dz := src[jp + i] - src[jm + i]
			var slope := 1.0 - span / sqrt(span * span + dx * dx + dz * dz)
			var c := layout.control(origin + i * cell, origin + j * cell, h, slope)
			var k := (cj * m + ci) * 4
			out[k] = int(c.r * 255.0)
			out[k + 1] = int(c.g * 255.0)
			out[k + 2] = int(c.b * 255.0)
			out[k + 3] = int(c.a * 255.0)
	return out


func _load_cache() -> bool:
	if not FileAccess.file_exists(CACHE_PATH):
		return false
	var f := FileAccess.open(CACHE_PATH, FileAccess.READ)
	if f == null or f.get_32() != CACHE_MAGIC or f.get_32() != WorldLayout.SAMPLES or f.get_pascal_string() != _layout_hash():
		return false
	heights = f.get_buffer(f.get_32()).to_float32_array()
	control = f.get_buffer(f.get_32())
	outer_heights = f.get_buffer(f.get_32()).to_float32_array()
	outer_control = f.get_buffer(f.get_32())
	return heights.size() == WorldLayout.SAMPLES * WorldLayout.SAMPLES \
		and outer_heights.size() == WorldLayout.OUTER_SAMPLES * WorldLayout.OUTER_SAMPLES


func _save_cache() -> void:
	var f := FileAccess.open(CACHE_PATH, FileAccess.WRITE)
	if f == null:
		return
	f.store_32(CACHE_MAGIC)
	f.store_32(WorldLayout.SAMPLES)
	f.store_pascal_string(_layout_hash())
	for buf: PackedByteArray in [heights.to_byte_array(), control, outer_heights.to_byte_array(), outer_control]:
		f.store_32(buf.size())
		f.store_buffer(buf)


## Cache key: changes whenever the layout script (the terrain function) changes.
func _layout_hash() -> String:
	return FileAccess.get_md5("res://scripts/world/world_layout.gd") + FileAccess.get_md5("res://scripts/world/world_terrain.gd")


# --- queries -------------------------------------------------------------------------------

## Height of the triangulated grid (diagonal from (i+1, j) to (i, j+1), as the Jolt height field).
func height_at(x: float, z: float) -> float:
	var fx := (x + WorldLayout.HALF) / WorldLayout.CELL
	var fz := (z + WorldLayout.HALF) / WorldLayout.CELL
	if fx < 0.0 or fz < 0.0 or fx >= WorldLayout.SAMPLES - 1 or fz >= WorldLayout.SAMPLES - 1:
		return _outer_height_at(x, z)
	var i := int(fx)
	var j := int(fz)
	var tx := fx - i
	var tz := fz - j
	var n := WorldLayout.SAMPLES
	var k := j * n + i
	var h00 := heights[k]
	var h10 := heights[k + 1]
	var h01 := heights[k + n]
	if tx + tz <= 1.0:
		return h00 + tx * (h10 - h00) + tz * (h01 - h00)
	var h11 := heights[k + n + 1]
	return h11 + (1.0 - tx) * (h01 - h11) + (1.0 - tz) * (h10 - h11)


func _outer_height_at(x: float, z: float) -> float:
	var n := WorldLayout.OUTER_SAMPLES
	var fx := clampf((x + WorldLayout.OUTER_HALF) / WorldLayout.OUTER_CELL, 0.0, n - 1.001)
	var fz := clampf((z + WorldLayout.OUTER_HALF) / WorldLayout.OUTER_CELL, 0.0, n - 1.001)
	var i := int(fx)
	var j := int(fz)
	var tx := fx - i
	var tz := fz - j
	var k := j * n + i
	var a := lerpf(outer_heights[k], outer_heights[k + 1], tx)
	var b := lerpf(outer_heights[k + n], outer_heights[k + n + 1], tx)
	return lerpf(a, b, tz)


## Control texel (forest, urban, airport, farm) at a world position, bilinear.
func control_at(x: float, z: float) -> Color:
	var m := (WorldLayout.SAMPLES - 1) / WorldLayout.CTL_STEP + 1
	var cell := WorldLayout.CELL * WorldLayout.CTL_STEP
	var fx := clampf((x + WorldLayout.HALF) / cell, 0.0, m - 1.001)
	var fz := clampf((z + WorldLayout.HALF) / cell, 0.0, m - 1.001)
	var i := int(fx)
	var j := int(fz)
	var tx := fx - i
	var tz := fz - j
	var out := Color(0, 0, 0, 0)
	for c in 4:
		var k := (j * m + i) * 4 + c
		var a := lerpf(control[k], control[k + 4], tx)
		var b := lerpf(control[k + m * 4], control[k + m * 4 + 4], tx)
		out[c] = lerpf(a, b, tz) / 255.0
	return out


# --- scene -------------------------------------------------------------------------------

func build_nodes() -> void:
	var n := WorldLayout.SAMPLES
	height_texture = ImageTexture.create_from_image(Image.create_from_data(n, n, false, Image.FORMAT_RF, heights.to_byte_array()))
	var m := (n - 1) / WorldLayout.CTL_STEP + 1
	control_texture = ImageTexture.create_from_image(Image.create_from_data(m, m, false, Image.FORMAT_RGBA8, control))
	var on := WorldLayout.OUTER_SAMPLES
	outer_height_texture = ImageTexture.create_from_image(Image.create_from_data(on, on, false, Image.FORMAT_RF, outer_heights.to_byte_array()))
	outer_control_texture = ImageTexture.create_from_image(Image.create_from_data(on, on, false, Image.FORMAT_RGBA8, outer_control))

	var shader: Shader = load("res://shaders/terrain.gdshader")
	material = ShaderMaterial.new()
	material.shader = shader
	_set_maps(material, height_texture, control_texture, -WorldLayout.HALF, WorldLayout.CELL, n,
		WorldLayout.CELL * WorldLayout.CTL_STEP, m)
	outer_material = ShaderMaterial.new()
	outer_material.shader = shader
	_set_maps(outer_material, outer_height_texture, outer_control_texture, -WorldLayout.OUTER_HALF,
		WorldLayout.OUTER_CELL, on, WorldLayout.OUTER_CELL, on)

	# Inner chunks: shared flat grids, displaced in the vertex shader.
	var chunk_size := CHUNK_CELLS * WorldLayout.CELL
	var lod0 := _grid_mesh(CHUNK_CELLS, WorldLayout.CELL, 25.0)
	var lod1 := _grid_mesh(CHUNK_CELLS / LOD1_STEP, WorldLayout.CELL * LOD1_STEP, 120.0)
	var chunks := (n - 1) / CHUNK_CELLS
	for cj in chunks:
		for ci in chunks:
			var center := Vector3(-WorldLayout.HALF + (ci + 0.5) * chunk_size, 0.0, -WorldLayout.HALF + (cj + 0.5) * chunk_size)
			var hr := _chunk_range(ci * CHUNK_CELLS, cj * CHUNK_CELLS, CHUNK_CELLS)
			var aabb := AABB(Vector3(-chunk_size * 0.5, hr.x - 130.0, -chunk_size * 0.5), Vector3(chunk_size, hr.y - hr.x + 140.0, chunk_size))
			_add_chunk(lod0, material, center, aabb, 0.0, LOD0_RANGE, true)
			_add_chunk(lod1, material, center, aabb, LOD0_RANGE, 0.0, false)

	# Outer ring: 20 km chunks around the playable square.
	var osize := OUTER_CHUNK_CELLS * WorldLayout.OUTER_CELL
	var omesh := _grid_mesh(OUTER_CHUNK_CELLS, WorldLayout.OUTER_CELL, 250.0)
	var ochunks := (on - 1) / OUTER_CHUNK_CELLS
	for cj in ochunks:
		for ci in ochunks:
			var center := Vector3(-WorldLayout.OUTER_HALF + (ci + 0.5) * osize, 0.0, -WorldLayout.OUTER_HALF + (cj + 0.5) * osize)
			if absf(center.x) < WorldLayout.HALF and absf(center.z) < WorldLayout.HALF:
				continue
			var aabb := AABB(Vector3(-osize * 0.5, -400.0, -osize * 0.5), Vector3(osize, 3400.0, osize))
			_add_chunk(omesh, outer_material, center, aabb, 0.0, 0.0, false)

	# Collision: one height field, uniformly scaled so its grid spacing equals CELL.
	var body := StaticBody3D.new()
	body.name = "TerrainBody"
	body.collision_layer = 1
	body.collision_mask = 0
	var shape := HeightMapShape3D.new()
	shape.map_width = n
	shape.map_depth = n
	var scaled := heights.duplicate()
	var inv := 1.0 / WorldLayout.CELL
	for k in scaled.size():
		scaled[k] *= inv
	shape.map_data = scaled
	var cs := CollisionShape3D.new()
	cs.shape = shape
	cs.scale = Vector3.ONE * WorldLayout.CELL
	body.add_child(cs)
	add_child(body)


func _set_maps(mat: ShaderMaterial, hm: Texture2D, ctl: Texture2D, origin: float, cell: float, size: int, ctl_cell: float, ctl_size: int) -> void:
	mat.set_shader_parameter("heightmap", hm)
	mat.set_shader_parameter("controlmap", ctl)
	mat.set_shader_parameter("hm_origin", Vector2(origin, origin))
	mat.set_shader_parameter("hm_cell", cell)
	mat.set_shader_parameter("hm_size", size)
	mat.set_shader_parameter("ctl_cell", ctl_cell)
	mat.set_shader_parameter("ctl_size", ctl_size)
	mat.set_shader_parameter("grid_origin", WorldLayout.GRID_ORIGIN)
	mat.set_shader_parameter("grid_pitch", WorldLayout.GRID_PITCH)


func _chunk_range(i0: int, j0: int, cells: int) -> Vector2:
	var n := WorldLayout.SAMPLES
	var lo := INF
	var hi := -INF
	for j in range(j0, j0 + cells + 1):
		for i in range(i0, i0 + cells + 1):
			var h := heights[j * n + i]
			lo = minf(lo, h)
			hi = maxf(hi, h)
	return Vector2(lo, hi)


func _add_chunk(mesh: Mesh, mat: Material, center: Vector3, aabb: AABB, begin: float, end: float, shadows: bool) -> void:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = center
	mi.custom_aabb = aabb
	mi.visibility_range_begin = begin
	mi.visibility_range_end = end
	if begin > 0.0:
		mi.visibility_range_begin_margin = 100.0
	if end > 0.0:
		mi.visibility_range_end_margin = 100.0
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)


## Flat (cells x cells) grid centred on the origin, with a skirt; UV2.x = skirt depth.
## Quads split along (i+1, j)-(i, j+1) to match the height field collision.
func _grid_mesh(cells: int, step: float, skirt: float) -> ArrayMesh:
	var verts := PackedVector3Array()
	var uv2 := PackedVector2Array()
	var normals := PackedVector3Array()
	var idx := PackedInt32Array()
	var half := cells * step * 0.5
	var row := cells + 1
	for j in row:
		for i in row:
			verts.append(Vector3(i * step - half, 0.0, j * step - half))
			uv2.append(Vector2.ZERO)
			normals.append(Vector3.UP)
	for j in cells:
		for i in cells:
			var v00 := j * row + i
			var v10 := v00 + 1
			var v01 := v00 + row
			var v11 := v01 + 1
			# Clockwise seen from above = front face in Godot.
			idx.append_array([v00, v10, v01, v10, v11, v01])
	# Skirt: walk the border clockwise (seen from above) and hang a strip under it.
	var border := PackedInt32Array()
	for i in cells:
		border.append(i)                          # north edge, west -> east
	for j in cells:
		border.append(j * row + cells)            # east edge, north -> south
	for i in range(cells, 0, -1):
		border.append(cells * row + i)            # south edge, east -> west
	for j in range(cells, 0, -1):
		border.append(j * row)                    # west edge, south -> north
	var base := verts.size()
	for b in border:
		verts.append(verts[b])
		uv2.append(Vector2(skirt, 0.0))
		normals.append(Vector3.UP)
	var count := border.size()
	for k in count:
		var a := border[k]
		var b := border[(k + 1) % count]
		var sa := base + k
		var sb := base + (k + 1) % count
		idx.append_array([a, sb, b, a, sa, sb])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV2] = uv2
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
