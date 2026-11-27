class_name World
extends Node3D
## Skybreak world: 40 x 40 km of coast, strait, hills, farmland and mountains with Port Calder, Sunmere and
## Ridgeway, four airports and a suspension bridge. See local world contract for the public API.

signal progress(fraction: float, text: String)

static var instance: World

const HASH_CELL := 250.0
const TIMES := ["dawn", "noon", "sunset", "night"]

var airports: Array[Dictionary] = []
var cities: Array[Dictionary] = []
var buildings: Array[AABB] = []
var bridge_gate: Dictionary = {}
var sun: DirectionalLight3D
var environment: Environment
var time_of_day := "noon"

var layout: WorldLayout
var terrain: WorldTerrain
var building_count := 0
var city_building_counts := {}
var tree_count := 0
var roof_probes: Array[Vector3] = []
var street_probes: Array[Vector3] = []

var _airports_builder: WorldAirports
var _hash := {}
var _course: Array[Transform3D] = []
var _ocean: MeshInstance3D
var _water_mat: ShaderMaterial
var _building_mat: ShaderMaterial
var _airport_light_mat: ShaderMaterial
var _street_light_mat: ShaderMaterial
var _obstacle_light_mat: ShaderMaterial
var _street_lights_node: Node3D
var _world_env: WorldEnvironment
var _sky: WorldSky
var _built := false


func _enter_tree() -> void:
	instance = self


func _exit_tree() -> void:
	if instance == self:
		instance = null


func _process(_delta: float) -> void:
	if _ocean == null:
		return
	var cam := get_viewport().get_camera_3d()
	if cam:
		var p := cam.global_position
		_ocean.global_position = Vector3(snappedf(p.x, 1000.0), 0.0, snappedf(p.z, 1000.0))


# --- build -------------------------------------------------------------------------------

func build(p_time_of_day: String) -> void:
	if _built:
		set_time_of_day(p_time_of_day)
		return
	_built = true
	var t0 := Time.get_ticks_msec()
	layout = WorldLayout.new()
	_step(0.0, "Setting up the sky")
	_build_environment()
	await get_tree().process_frame

	terrain = WorldTerrain.new(layout)
	add_child(terrain)
	await terrain.generate(func(f: float) -> void: _step(0.02 + 0.5 * f, "Shaping terrain"))
	_step(0.52, "Building terrain")
	await get_tree().process_frame
	terrain.build_nodes()
	_build_ocean()
	_step(0.6, "Building airports")
	await get_tree().process_frame

	var structures := StaticBody3D.new()
	structures.name = "Structures"
	structures.collision_layer = 1
	structures.collision_mask = 0
	add_child(structures)
	var main := GeoBatch.new(structures, 1000.0)
	var detail := GeoBatch.new(structures, 1000.0)
	_building_mat = ShaderMaterial.new()
	_building_mat.shader = load("res://shaders/building.gdshader")

	var airports_node := Node3D.new()
	airports_node.name = "Airports"
	add_child(airports_node)
	_airports_builder = WorldAirports.new(layout, terrain, main)
	_airports_builder.build(airports_node)
	airports.assign(_airports_builder.airports)

	_step(0.68, "Building cities")
	await get_tree().process_frame
	var city_builder := WorldCities.new(layout, terrain, main, detail)
	city_builder.build_all()
	building_count = city_builder.building_count
	city_building_counts = city_builder.city_counts
	roof_probes = city_builder.roof_probes
	street_probes = city_builder.street_probes
	for c in layout.city_zones:
		var center: Vector2 = c.center
		cities.append({"name": c.name, "center": Vector3(center.x, c.elev, center.y), "radius": c.suburb})

	_step(0.8, "Building the bridge")
	await get_tree().process_frame
	var bridge := WorldBridge.new(layout, terrain, main)
	bridge.build()
	bridge_gate = bridge.gate

	buildings.assign(main.aabbs)
	buildings.append_array(detail.aabbs)
	_build_hash()
	var city_node := Node3D.new()
	city_node.name = "Cities"
	add_child(city_node)
	main.build(city_node, _building_mat)
	detail.build(city_node, _building_mat, 4500.0)

	_step(0.86, "Planting forests")
	await get_tree().process_frame
	var forest_node := Node3D.new()
	forest_node.name = "Forests"
	add_child(forest_node)
	var forest := WorldForest.new(layout, terrain)
	forest.build(forest_node, city_builder.park_trees, func(p: Vector3) -> bool: return buildings_near(p, 20.0).is_empty())
	tree_count = forest.tree_count

	_step(0.95, "Switching on the lights")
	await get_tree().process_frame
	_build_lights(_airports_builder.lights, city_builder.street_lights + bridge.deck_lights,
		city_builder.obstacle_lights + bridge.obstacle_lights)
	_build_course()
	set_time_of_day(p_time_of_day)
	_step(1.0, "Ready")
	print("World built in %d ms: %d buildings %s, %d boxes, %d trees" % [Time.get_ticks_msec() - t0, building_count, city_building_counts, buildings.size(), tree_count])


func _step(f: float, text: String) -> void:
	progress.emit(f, text)


# --- queries -------------------------------------------------------------------------------

func height_at(x: float, z: float) -> float:
	return terrain.height_at(x, z)


func surface_height_at(x: float, z: float) -> float:
	return maxf(terrain.height_at(x, z), 0.0)


func is_over_water(x: float, z: float) -> bool:
	return terrain.height_at(x, z) < 0.0


func runway_start_transform(airport_index: int, reverse := false) -> Transform3D:
	return _airports_builder.runway_start_transform(airport_index, reverse)


func approach_transform(airport_index: int, distance: float, reverse := false) -> Transform3D:
	return _airports_builder.approach_transform(airport_index, distance, reverse)


func _build_hash() -> void:
	_hash.clear()
	for k in buildings.size():
		var b := buildings[k]
		for cz in range(floori(b.position.z / HASH_CELL), floori(b.end.z / HASH_CELL) + 1):
			for cx in range(floori(b.position.x / HASH_CELL), floori(b.end.x / HASH_CELL) + 1):
				var key := Vector2i(cx, cz)
				if not _hash.has(key):
					_hash[key] = PackedInt32Array()
				var list: PackedInt32Array = _hash[key]
				list.append(k)
				_hash[key] = list


func buildings_near(pos: Vector3, radius: float) -> Array[AABB]:
	var out: Array[AABB] = []
	var seen := {}
	var r2 := radius * radius
	for cz in range(floori((pos.z - radius) / HASH_CELL), floori((pos.z + radius) / HASH_CELL) + 1):
		for cx in range(floori((pos.x - radius) / HASH_CELL), floori((pos.x + radius) / HASH_CELL) + 1):
			var list: PackedInt32Array = _hash.get(Vector2i(cx, cz), PackedInt32Array())
			for k in list:
				if seen.has(k):
					continue
				seen[k] = true
				var b := buildings[k]
				var q := pos.clamp(b.position, b.end)
				if q.distance_squared_to(pos) <= r2:
					out.append(b)
	return out


func skyline_course() -> Array[Transform3D]:
	return _course.duplicate()


## Skyline Run: in from the east along a downtown avenue, an S-bend across the central park onto the next
## avenue, out over the strait, a left turn down the channel, under the bridge and out to the strait mouth.
func _build_course() -> void:
	var z1 := WorldLayout.GRID_ORIGIN.y + 6.0 * WorldLayout.GRID_PITCH    # 60 m avenue
	var z2 := WorldLayout.GRID_ORIGIN.y + 8.0 * WorldLayout.GRID_PITCH    # 60 m avenue
	var park_x := (WorldLayout.PARK_MIN.x + WorldLayout.PARK_MAX.x) * 0.5
	var west_x := WorldLayout.GRID_ORIGIN.x + 6.0 * WorldLayout.GRID_PITCH  # avenue on the park's west side
	var street := WorldLayout.CALDER_ELEV
	var xs := layout.strait_x(WorldLayout.BRIDGE_Z)
	var gate_c: Vector3 = bridge_gate.center
	var pts: Array[Vector3] = [
		Vector3(5600.0, 0.0, z1), Vector3(4700.0, 0.0, z1), Vector3(3800.0, 0.0, z1),
		Vector3(2900.0, street + 80.0, z1), Vector3(2150.0, street + 70.0, z1), Vector3(1450.0, street + 60.0, z1),
		Vector3(900.0, street + 55.0, z1), Vector3(park_x, street + 50.0, (z1 + z2) * 0.5),
		Vector3(west_x, street + 48.0, z2), Vector3(-60.0, street + 50.0, z2), Vector3(-420.0, street + 55.0, z2),
		Vector3(-800.0, street + 55.0, z2), Vector3(layout.strait_x(z2 + 80.0) + 230.0, 55.0, z2 + 80.0),
		Vector3(layout.strait_x(2850.0) + 40.0, 50.0, 2850.0), Vector3(layout.strait_x(3400.0), 42.0, 3400.0),
		gate_c, Vector3(layout.strait_x(4600.0), 38.0, 4600.0), Vector3(layout.strait_x(5300.0), 50.0, 5300.0),
		Vector3(layout.strait_x(6100.0) + 60.0, 65.0, 6100.0),
	]
	# Rings outside the city ride 60 m above the ground.
	for k in 3:
		pts[k].y = maxf(surface_height_at(pts[k].x, pts[k].z), street) + 65.0
	_course.clear()
	for k in pts.size():
		var prev := pts[maxi(k - 1, 0)]
		var next := pts[mini(k + 1, pts.size() - 1)]
		var d := next - prev
		d.y *= 0.3
		var b := Basis.looking_at(d.normalized(), Vector3.UP)
		if k == 15:
			b = bridge_gate.basis
		_course.append(Transform3D(b, pts[k]))


# --- scene pieces -------------------------------------------------------------------------

func _build_ocean() -> void:
	_water_mat = ShaderMaterial.new()
	_water_mat.shader = load("res://shaders/water.gdshader")
	_water_mat.set_shader_parameter("hm_inner", terrain.height_texture)
	_water_mat.set_shader_parameter("hm_outer", terrain.outer_height_texture)
	var plane := PlaneMesh.new()
	plane.size = Vector2(170000.0, 170000.0)
	plane.subdivide_width = 32
	plane.subdivide_depth = 32
	_ocean = MeshInstance3D.new()
	_ocean.name = "Ocean"
	_ocean.mesh = plane
	_ocean.material_override = _water_mat
	_ocean.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_ocean.extra_cull_margin = 1000.0
	add_child(_ocean)


func _build_lights(airport: Array[Dictionary], street: Array[Vector3], obstacle: Array[Vector3]) -> void:
	var shader: Shader = load("res://shaders/runway_lights.gdshader")
	_airport_light_mat = _light_mat(shader, 0.3)
	_street_light_mat = _light_mat(shader, 0.9)
	_obstacle_light_mat = _light_mat(shader, 0.2)
	var quad := QuadMesh.new()
	quad.size = Vector2(1.0, 1.0)

	var mm := _light_multimesh(quad, airport.size())
	for k in airport.size():
		var l: Dictionary = airport[k]
		mm.set_instance_transform(k, Transform3D(Basis.IDENTITY, l.pos))
		mm.set_instance_color(k, l.color)
		mm.set_instance_custom_data(k, Color(l.size, l.papi, -1.0, 0.0))
	_add_light_node("AirportLights", mm, _airport_light_mat)

	mm = _light_multimesh(quad, street.size())
	for k in street.size():
		mm.set_instance_transform(k, Transform3D(Basis.IDENTITY, street[k]))
		mm.set_instance_color(k, Color(1.0, 0.62, 0.3))
		mm.set_instance_custom_data(k, Color(1.6, 0.0, -1.0, 0.0))
	_street_lights_node = _add_light_node("StreetLights", mm, _street_light_mat)

	mm = _light_multimesh(quad, obstacle.size())
	for k in obstacle.size():
		mm.set_instance_transform(k, Transform3D(Basis.IDENTITY, obstacle[k]))
		mm.set_instance_color(k, Color(1.0, 0.08, 0.05))
		mm.set_instance_custom_data(k, Color(1.5, 0.0, fmod(k * 0.137, 1.0), 0.0))
	_add_light_node("ObstacleLights", mm, _obstacle_light_mat)


func _light_mat(shader: Shader, far_falloff: float) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = shader
	m.set_shader_parameter("far_falloff", far_falloff)
	return m


func _light_multimesh(mesh: Mesh, count: int) -> MultiMesh:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = mesh
	mm.instance_count = count
	return mm


func _add_light_node(node_name: String, mm: MultiMesh, mat: Material) -> MultiMeshInstance3D:
	var mmi := MultiMeshInstance3D.new()
	mmi.name = node_name
	mmi.multimesh = mm
	mmi.material_override = mat
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mmi.extra_cull_margin = 200.0
	mmi.custom_aabb = AABB(Vector3(-60000, -1000, -60000), Vector3(120000, 5000, 120000))
	add_child(mmi)
	return mmi


func _build_environment() -> void:
	environment = Environment.new()
	environment.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	sky.radiance_size = Sky.RADIANCE_SIZE_256
	_sky = WorldSky.new()
	sky.sky_material = _sky.material
	environment.sky = sky
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	environment.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	environment.tonemap_mode = Environment.TONE_MAPPER_ACES
	environment.tonemap_white = 6.0
	environment.glow_enabled = true
	environment.glow_blend_mode = Environment.GLOW_BLEND_MODE_ADDITIVE
	environment.glow_intensity = 0.35
	environment.glow_hdr_threshold = 1.1
	environment.set_glow_level(1, 1.0)
	environment.set_glow_level(3, 1.0)
	environment.set_glow_level(5, 0.6)
	environment.fog_enabled = true
	environment.fog_mode = Environment.FOG_MODE_EXPONENTIAL
	environment.fog_aerial_perspective = 0.85
	environment.fog_sky_affect = 0.0
	environment.ssao_enabled = true
	environment.ssao_radius = 2.0
	environment.ssao_intensity = 1.4
	environment.adjustment_enabled = true

	_world_env = WorldEnvironment.new()
	_world_env.environment = environment
	add_child(_world_env)

	sun = DirectionalLight3D.new()
	sun.name = "Sun"
	sun.shadow_enabled = true
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.directional_shadow_max_distance = 1500.0
	sun.directional_shadow_blend_splits = true
	sun.directional_shadow_split_1 = 0.05
	sun.directional_shadow_split_2 = 0.15
	sun.directional_shadow_split_3 = 0.4
	sun.shadow_bias = 0.08
	sun.shadow_normal_bias = 1.5
	add_child(sun)


## Switches sun, sky, fog, ambient and night lighting without rebuilding anything.
func set_time_of_day(p_time_of_day: String) -> void:
	time_of_day = p_time_of_day if p_time_of_day in TIMES else "noon"
	if environment == null:
		return
	var night := time_of_day == "night"
	var p: Dictionary
	var sky: Dictionary
	match time_of_day:
		"dawn":
			p = {"elev": 7.0, "az": 98.0, "col": Color(1.0, 0.72, 0.5), "energy": 1.6, "fog": Color(0.8, 0.7, 0.66),
				"density": 0.00005, "windows": 0.45, "exposure": 1.15, "lights": 2.5, "street": 0.8}
			sky = {"zenith": Color(0.18, 0.28, 0.52), "horizon": Color(0.86, 0.72, 0.64), "sun_glow": Color(1.0, 0.62, 0.35),
				"glow_strength": 1.2, "anti_glow": Color(0.55, 0.48, 0.62), "anti_strength": 0.6, "ground": Color(0.3, 0.28, 0.28),
				"cloud_lit": Color(1.0, 0.76, 0.6), "cloud_shade": Color(0.42, 0.42, 0.52), "cloud_cover": 0.38, "stars": 0.0,
				"brightness": 0.8, "disk_energy": 30.0}
		"sunset":
			p = {"elev": 5.0, "az": 262.0, "col": Color(1.0, 0.62, 0.38), "energy": 1.7, "fog": Color(0.86, 0.66, 0.52),
				"density": 0.000045, "windows": 0.5, "exposure": 1.15, "lights": 2.5, "street": 0.9}
			sky = {"zenith": Color(0.16, 0.24, 0.48), "horizon": Color(0.93, 0.67, 0.48), "sun_glow": Color(1.0, 0.5, 0.2),
				"glow_strength": 1.6, "anti_glow": Color(0.6, 0.5, 0.62), "anti_strength": 0.7, "ground": Color(0.3, 0.26, 0.25),
				"cloud_lit": Color(1.0, 0.64, 0.4), "cloud_shade": Color(0.45, 0.38, 0.46), "cloud_cover": 0.4, "stars": 0.0,
				"brightness": 0.85, "disk_energy": 30.0}
		"night":
			p = {"elev": 38.0, "az": 205.0, "col": Color(0.6, 0.7, 1.0), "energy": 0.16, "fog": Color(0.04, 0.05, 0.08),
				"density": 0.00004, "windows": 1.0, "exposure": 1.3, "lights": 5.0, "street": 1.2}
			sky = {"zenith": Color(0.012, 0.018, 0.04), "horizon": Color(0.05, 0.06, 0.09), "sun_glow": Color(0.4, 0.45, 0.6),
				"glow_strength": 0.15, "anti_glow": Color(0, 0, 0), "anti_strength": 0.0, "ground": Color(0.01, 0.012, 0.016),
				"cloud_lit": Color(0.1, 0.11, 0.14), "cloud_shade": Color(0.035, 0.04, 0.055), "cloud_cover": 0.3, "stars": 1.5,
				"brightness": 1.0, "disk_energy": 6.0}
		_:
			p = {"elev": 58.0, "az": 160.0, "col": Color(1.0, 0.97, 0.92), "energy": 1.8, "fog": Color(0.7, 0.78, 0.88),
				"density": 0.000028, "windows": 0.0, "exposure": 1.0, "lights": 1.0, "street": 0.0}
			sky = {"zenith": Color(0.22, 0.42, 0.78), "horizon": Color(0.7, 0.79, 0.9), "sun_glow": Color(1.0, 0.95, 0.85),
				"glow_strength": 0.35, "anti_glow": Color(0, 0, 0), "anti_strength": 0.0, "ground": Color(0.35, 0.37, 0.38),
				"cloud_lit": Color(1.0, 1.0, 1.0), "cloud_shade": Color(0.62, 0.66, 0.74), "cloud_cover": 0.42, "stars": 0.0,
				"brightness": 1.0, "disk_energy": 40.0}
	var el := deg_to_rad(p.elev)
	var az := deg_to_rad(p.az)
	var to_sun := Vector3(sin(az) * cos(el), sin(el), -cos(az) * cos(el))
	sun.basis = Basis.looking_at(-to_sun, Vector3.UP)
	sun.light_color = p.col
	sun.light_energy = p.energy
	sun.sky_mode = DirectionalLight3D.SKY_MODE_LIGHT_AND_SKY
	sun.shadow_opacity = 0.6 if night else 1.0
	_sky.apply(sky)
	environment.ambient_light_sky_contribution = 1.0
	environment.ambient_light_energy = 1.0
	if night:
		environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		environment.ambient_light_color = Color(0.06, 0.07, 0.11)
	else:
		environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	environment.fog_light_color = p.fog
	environment.fog_density = p.density
	environment.fog_sun_scatter = 0.0 if night else 0.2
	environment.tonemap_exposure = p.exposure
	if _building_mat:
		_building_mat.set_shader_parameter("night", p.windows)
	if _airport_light_mat:
		_airport_light_mat.set_shader_parameter("intensity", p.lights)
		_obstacle_light_mat.set_shader_parameter("intensity", maxf(p.lights, 2.0))
		_street_light_mat.set_shader_parameter("intensity", p.street)
		_street_lights_node.visible = p.street > 0.0
	if _water_mat:
		_water_mat.set_shader_parameter("sun_glint", 0.6 if night else 1.0)
