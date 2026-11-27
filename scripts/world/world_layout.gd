class_name WorldLayout
extends RefCounted
## The static world design: coastline, strait, mountains, valley, flatten zones, airports and cities.
## `height(x, z)` is the analytic terrain function that gets sampled into the heightmap grid.
## Every method is read-only after _init, so it is safe to call from worker threads.

const HALF := 20000.0
const SAMPLES := 1025
const CELL := 40000.0 / 1024.0
const CTL_STEP := 2                              # control map = every 2nd heightmap sample
const OUTER_HALF := 80000.0
const OUTER_SAMPLES := 257
const OUTER_CELL := 160000.0 / 256.0

const COAST_BASE := 7600.0
const BRIDGE_Z := 4000.0
const STRAIT_HALF_WIDTH := 560.0
const CALDER_ELEV := 12.0
const CALDER_CENTER := Vector2(450.0, 2250.0)
const DOWNTOWN_MIN := Vector2(-760.0, 950.0)
const DOWNTOWN_MAX := Vector2(1700.0, 3560.0)
const SKYLINE_FOCUS := Vector2(950.0, 1850.0)
const PARK_MIN := Vector2(360.0, 2080.0)
const PARK_MAX := Vector2(720.0, 2440.0)
## Street grid shared by every town: line k sits at origin + k * pitch; even lines are 60 m avenues,
## odd lines 40 m streets, leaving 130 m blocks.
const GRID_ORIGIN := Vector2(-720.0, 1000.0)
const GRID_PITCH := 180.0
const AVENUE_W := 60.0
const STREET_W := 40.0

const AIRPORT_DEFS := [
	{"name": "Calder International", "code": "CDI", "x": 6800.0, "z": -1200.0, "heading": 80.0,
		"length": 3500.0, "width": 45.0, "elevation": 24.0, "military": false},
	{"name": "Falcon AFB", "code": "FAB", "x": -12500.0, "z": 600.0, "heading": 10.0,
		"length": 3000.0, "width": 45.0, "elevation": 70.0, "military": true},
	{"name": "Ridgeway", "code": "RGW", "x": 2000.0, "z": -13000.0, "heading": 160.0,
		"length": 2400.0, "width": 40.0, "elevation": 625.0, "military": false},
	{"name": "Sunmere", "code": "SNM", "x": 12800.0, "z": 2600.0, "heading": 120.0,
		"length": 2600.0, "width": 45.0, "elevation": 18.0, "military": false},
]
const AIRPORT_FLAT_ALONG := 520.0   # flat margin past each runway end
const AIRPORT_FLAT_LEFT := -260.0   # flat area across the runway (right side holds taxiway, apron, terminal)
const AIRPORT_FLAT_RIGHT := 560.0
const AIRPORT_BLEND := 1000.0

const VALLEY_LENGTH := 9500.0
const VALLEY_BACK := 7500.0

## City zones: center, elevation, flat radius, blend radius, core (paved) radius, suburb radius.
var city_zones: Array[Dictionary] = []
var airport_zones: Array[Dictionary] = []
var valley_a := Vector2.ZERO
var valley_dir := Vector2.ZERO

var _n_coast: FastNoiseLite
var _n_jitter: FastNoiseLite
var _n_hills: FastNoiseLite
var _n_ridge: FastNoiseLite
var _n_mass: FastNoiseLite
var _n_warp: FastNoiseLite
var _n_detail: FastNoiseLite
var _n_forest: FastNoiseLite
var _n_farm: FastNoiseLite


func _init() -> void:
	_n_coast = _noise(11, 1.0 / 7000.0, 4)
	_n_jitter = _noise(12, 1.0 / 1800.0, 3)
	_n_hills = _noise(13, 1.0 / 3800.0, 5)
	_n_ridge = _noise(14, 1.0 / 8500.0, 6)
	_n_ridge.fractal_type = FastNoiseLite.FRACTAL_RIDGED
	_n_ridge.fractal_lacunarity = 2.1
	_n_mass = _noise(15, 1.0 / 16000.0, 2)
	_n_warp = _noise(16, 1.0 / 5000.0, 2)
	_n_detail = _noise(17, 1.0 / 700.0, 3)
	_n_forest = _noise(18, 1.0 / 2600.0, 4)
	_n_farm = _noise(19, 1.0 / 4500.0, 2)

	for d in AIRPORT_DEFS:
		var h: float = deg_to_rad(d.heading)
		airport_zones.append({
			"pos": Vector2(d.x, d.z), "dir": Vector2(sin(h), -cos(h)), "right": Vector2(cos(h), sin(h)),
			"half": d.length * 0.5, "elev": d.elevation,
		})
	var rw: Dictionary = airport_zones[2]
	valley_a = rw.pos
	valley_dir = rw.dir

	var sunmere := Vector2(14700.0, coast_z(14700.0) - 1250.0)
	var ridge_town: Vector2 = valley_a + valley_dir * 2500.0 + Vector2(rw.right) * 750.0
	city_zones = [
		{"name": "Port Calder", "center": CALDER_CENTER, "elev": CALDER_ELEV, "r0": 3300.0, "r1": 5300.0,
			"core": 2650.0, "suburb": 4300.0},
		{"name": "Sunmere", "center": sunmere, "elev": 8.0, "r0": 1700.0, "r1": 2900.0,
			"core": 850.0, "suburb": 1900.0},
		{"name": "Ridgeway", "center": ridge_town, "elev": _valley_floor(2500.0), "r0": 650.0, "r1": 1500.0,
			"core": 0.0, "suburb": 800.0},
	]


func _noise(seed_value: int, freq: float, octaves: int) -> FastNoiseLite:
	var n := FastNoiseLite.new()
	n.seed = seed_value
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n.frequency = freq
	n.fractal_type = FastNoiseLite.FRACTAL_FBM
	n.fractal_octaves = octaves
	return n


static func smooth(e0: float, e1: float, x: float) -> float:
	var t := clampf((x - e0) / (e1 - e0), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


func coast_z(x: float) -> float:
	return COAST_BASE + _n_coast.get_noise_1d(x) * 1500.0 + 450.0 * sin(x / 2900.0 + 1.3)


## Signed distance inland from the coastline (negative at sea).
func coast_distance(x: float, z: float) -> float:
	return coast_z(x) - z + _n_jitter.get_noise_2d(x, z) * 650.0


func strait_x(z: float) -> float:
	return -1500.0 + 600.0 * (1.0 - cos((z - BRIDGE_Z) / 4000.0))


func strait_half_width(z: float) -> float:
	return STRAIT_HALF_WIDTH * smooth(-5500.0, -1800.0, z) + maxf(0.0, z - 6200.0) * 0.3


func _valley_floor(along: float) -> float:
	return lerpf(625.0, 140.0, clampf(along / VALLEY_LENGTH, 0.0, 1.0))


func height(x: float, z: float) -> float:
	var d := coast_distance(x, z)
	var h: float
	if d < 0.0:
		h = 2.0 - 72.0 * (1.0 - exp(d / 1100.0))
	else:
		var hills := _n_hills.get_noise_2d(x, z) * 0.5 + 0.5
		h = 2.0 + minf(d, 1500.0) * 0.006 + 45.0 * smooth(0.0, 6000.0, d) + hills * hills * 170.0 * smooth(150.0, 3500.0, d)
		h += _n_detail.get_noise_2d(x, z) * 6.0 * smooth(0.0, 600.0, d)
	# Northern mountains: ridged noise rising behind a warped front.
	var zz := z + _n_warp.get_noise_2d(x, z) * 2200.0
	var m := smooth(-4500.0, -10500.0, zz)
	if m > 0.0:
		var r := clampf(_n_ridge.get_noise_2d(x, z) * 0.5 + 0.5, 0.0, 1.0)
		var mass := _n_mass.get_noise_2d(x, z) * 0.5 + 0.5
		h += m * (180.0 + (1900.0 + 900.0 * mass) * pow(r, 1.9))
		h += m * _n_detail.get_noise_2d(x * 1.7, z * 1.7) * 45.0
	h = _apply_valley(x, z, h)
	h = _apply_cities(x, z, h, d)
	h = _apply_airports(x, z, h)
	h = _apply_strait(x, z, h)
	return h


func _apply_valley(x: float, z: float, h: float) -> float:
	var rel := Vector2(x, z) - valley_a
	var along := clampf(rel.dot(valley_dir), -VALLEY_BACK, VALLEY_LENGTH)
	var dv := Vector2(x, z).distance_to(valley_a + valley_dir * along)
	if dv > 3200.0:
		return h
	var floor_h := _valley_floor(maxf(along, 0.0)) + dv * 0.05 + _n_detail.get_noise_2d(x, z) * 12.0
	if floor_h >= h:
		return h
	var vm := 1.0 - smooth(1200.0, 3200.0, dv)
	if along <= -VALLEY_BACK + 1.0:   # close the valley head with a rising wall
		vm *= 1.0 - smooth(0.0, 1500.0, rel.dot(-valley_dir) - VALLEY_BACK)
	return lerpf(h, floor_h, vm)


func _apply_cities(x: float, z: float, h: float, d: float) -> float:
	for c in city_zones:
		var dist := Vector2(x, z).distance_to(c.center)
		if dist < c.r1:
			var f := (1.0 - smooth(c.r0, c.r1, dist)) * clampf(d / 400.0, 0.0, 1.0)
			h = lerpf(h, c.elev, f)
	return h


## Distance outside the flat rectangle of an airport (0 inside).
func airport_rect_distance(zone: Dictionary, x: float, z: float) -> float:
	var rel := Vector2(x, z) - Vector2(zone.pos)
	var a: float = absf(rel.dot(zone.dir)) - (zone.half + AIRPORT_FLAT_ALONG)
	var c: float = rel.dot(zone.right)
	var co := maxf(AIRPORT_FLAT_LEFT - c, c - AIRPORT_FLAT_RIGHT)
	return Vector2(maxf(a, 0.0), maxf(co, 0.0)).length()


func _apply_airports(x: float, z: float, h: float) -> float:
	for zone in airport_zones:
		var r := airport_rect_distance(zone, x, z)
		if r < AIRPORT_BLEND:
			h = lerpf(h, zone.elev, 1.0 - smooth(0.0, AIRPORT_BLEND, r))
	return h


func _apply_strait(x: float, z: float, h: float) -> float:
	var w := strait_half_width(z)
	if w < 1.0:
		return h
	var s := absf(x - strait_x(z))
	if s > w + 120.0:
		return h
	var mk := 1.0 - smooth(w - 25.0, w + 70.0, s)
	var bed := -30.0 + 20.0 * pow(clampf(s / w, 0.0, 1.0), 3.0)
	return minf(h, lerpf(h, bed, mk))


## Control texel: r forest density, g urban (1 paved core, 0.5 suburb), b airport grounds, a farmland.
func control(x: float, z: float, h: float, slope: float) -> Color:
	var urban := 0.0
	if h > 0.5:
		for c in city_zones:
			var dist := Vector2(x, z).distance_to(c.center)
			var u := 0.5 * (1.0 - smooth(c.suburb - 250.0, c.suburb + 150.0, dist))
			if c.core > 0.0:
				u = maxf(u, 1.0 - smooth(c.core - 200.0, c.core + 100.0, dist))
			urban = maxf(urban, u)
	var air := 0.0
	for zone in airport_zones:
		air = maxf(air, 1.0 - smooth(0.0, 80.0, airport_rect_distance(zone, x, z)))
	var forest := 0.0
	var farm := 0.0
	if urban < 0.25 and air < 0.1 and h > 6.0:
		var d := coast_distance(x, z)
		var tree_line := 1650.0 + _n_mass.get_noise_2d(x * 3.0, z * 3.0) * 250.0
		if h < tree_line and slope < 0.6 and d > 250.0:
			var fn := _n_forest.get_noise_2d(x, z) + smooth(250.0, 900.0, h) * 0.35 - smooth(1300.0, tree_line, h) * 0.5
			forest = smooth(0.02, 0.22, fn) * (1.0 - smooth(0.45, 0.6, slope))
		if h < 520.0 and slope < 0.12 and d > 900.0 and forest < 0.5:
			farm = smooth(-0.15, 0.15, _n_farm.get_noise_2d(x, z)) * (1.0 - smooth(0.06, 0.12, slope))
			farm *= 1.0 - smooth(250.0, 520.0, h)
			forest *= 1.0 - farm
	return Color(forest, urban, air, farm)
