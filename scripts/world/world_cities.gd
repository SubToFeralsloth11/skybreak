class_name WorldCities
extends RefCounted
## Procedural towns on the shared street grid: Port Calder (skyscraper downtown, mid-rise ring, suburbs),
## Sunmere and Ridgeway. Geometry goes into GeoBatches (merged meshes + per-box collision + AABBs).

const SIDEWALK := 4.0
const LOT_GAP := 4.0

var layout: WorldLayout
var terrain: WorldTerrain
var main: GeoBatch      # facades, collision, AABBs
var detail: GeoBatch    # rooftop units (short visibility range), collision, AABBs
var rng := RandomNumberGenerator.new()

## Outputs used by the world for lights, trees and tests.
var street_lights: Array[Vector3] = []
var obstacle_lights: Array[Vector3] = []
var park_trees: Array[Vector3] = []
var roof_probes: Array[Vector3] = []
var street_probes: Array[Vector3] = []
var building_count := 0
var city_counts := {}


func _init(p_layout: WorldLayout, p_terrain: WorldTerrain, p_main: GeoBatch, p_detail: GeoBatch) -> void:
	layout = p_layout
	terrain = p_terrain
	main = p_main
	detail = p_detail
	rng.seed = 7741


static func line_pos(origin: float, k: int) -> float:
	return origin + k * WorldLayout.GRID_PITCH


static func line_width(k: int) -> float:
	return WorldLayout.AVENUE_W if posmod(k, 2) == 0 else WorldLayout.STREET_W


func build_all() -> void:
	for c in layout.city_zones:
		_build_city(c)


func _build_city(c: Dictionary) -> void:
	var count_before := building_count
	var center: Vector2 = c.center
	var reach: float = c.suburb
	var go := WorldLayout.GRID_ORIGIN
	var kx0 := floori((center.x - reach - go.x) / WorldLayout.GRID_PITCH) - 1
	var kx1 := ceili((center.x + reach - go.x) / WorldLayout.GRID_PITCH) + 1
	var kz0 := floori((center.y - reach - go.y) / WorldLayout.GRID_PITCH) - 1
	var kz1 := ceili((center.y + reach - go.y) / WorldLayout.GRID_PITCH) + 1
	var is_calder: bool = c.name == "Port Calder"
	for kz in range(kz0, kz1):
		for kx in range(kx0, kx1):
			var x0 := line_pos(go.x, kx) + line_width(kx) * 0.5
			var x1 := line_pos(go.x, kx + 1) - line_width(kx + 1) * 0.5
			var z0 := line_pos(go.y, kz) + line_width(kz) * 0.5
			var z1 := line_pos(go.y, kz + 1) - line_width(kz + 1) * 0.5
			var bmin := Vector2(x0, z0)
			var bmax := Vector2(x1, z1)
			var bc := (bmin + bmax) * 0.5
			var dist := bc.distance_to(center)
			if dist > reach:
				continue
			if not _block_allowed(bmin, bmax):
				continue
			var ground := terrain.height_at(bc.x, bc.y)
			if is_calder and _in_rect(bc, WorldLayout.PARK_MIN, WorldLayout.PARK_MAX):
				_park(bmin, bmax, ground)
				continue
			var flat := _is_flat(bmin, bmax, c.elev)
			var downtown: bool = (is_calder and _in_rect(bc, WorldLayout.DOWNTOWN_MIN, WorldLayout.DOWNTOWN_MAX)) \
				or (not is_calder and dist < c.core * 0.55)
			if downtown and flat:
				_slab(bmin, bmax, ground)
				_downtown_block(bmin, bmax, ground, bc, c)
				var sp := Vector2(line_pos(go.x, kx), line_pos(go.y, kz))
				street_probes.append(Vector3(sp.x, terrain.height_at(sp.x, sp.y), sp.y))
			elif dist < c.core and flat:
				_slab(bmin, bmax, ground)
				_midrise_block(bmin, bmax, ground, dist / maxf(c.core, 1.0))
			elif dist < c.suburb:
				_suburb_block(bmin, bmax)
	_street_lights(c, kx0, kx1, kz0, kz1)
	city_counts[c.name] = building_count - count_before


func _in_rect(p: Vector2, a: Vector2, b: Vector2) -> bool:
	return p.x > a.x and p.x < b.x and p.y > a.y and p.y < b.y


## Keeps blocks off the bridge approaches and airfields.
func _block_allowed(bmin: Vector2, bmax: Vector2) -> bool:
	var bz := WorldLayout.BRIDGE_Z
	if bmax.y > bz - 110.0 and bmin.y < bz + 110.0 and bmax.x > -3600.0 and bmin.x < 700.0:
		return false
	var bc := (bmin + bmax) * 0.5
	for zone in layout.airport_zones:
		if layout.airport_rect_distance(zone, bc.x, bc.y) < 250.0:
			return false
	return true


func _is_flat(bmin: Vector2, bmax: Vector2, elev: float) -> bool:
	for p in [bmin, bmax, Vector2(bmin.x, bmax.y), Vector2(bmax.x, bmin.y), (bmin + bmax) * 0.5]:
		var h := terrain.height_at(p.x, p.y)
		if absf(h - elev) > 0.6 or h < 2.5:
			return false
	return true


func _slab(bmin: Vector2, bmax: Vector2, ground: float) -> void:
	main.add_block((bmin + bmax) * 0.5, bmax - bmin, ground - 1.0, ground + 0.2, Vector2(11, 0), Color(1, 1, 1), ground, false, false)


func _park(bmin: Vector2, bmax: Vector2, ground: float) -> void:
	main.add_block((bmin + bmax) * 0.5, bmax - bmin, ground - 1.0, ground + 0.15, Vector2(12, 0), Color(1, 1, 1), ground, false, false)
	for k in 14:
		park_trees.append(Vector3(rng.randf_range(bmin.x + 8, bmax.x - 8), ground + 0.15, rng.randf_range(bmin.y + 8, bmax.y - 8)))


## Splits a block into 1, 2 or 4 lots (inside the sidewalk).
func _lots(bmin: Vector2, bmax: Vector2, weights: Vector3) -> Array[Rect2]:
	var a := bmin + Vector2.ONE * SIDEWALK
	var b := bmax - Vector2.ONE * SIDEWALK
	var size := b - a
	var r := rng.randf() * (weights.x + weights.y + weights.z)
	var out: Array[Rect2] = []
	if r < weights.x:
		out.append(Rect2(a, size))
	elif r < weights.x + weights.y:
		var half := (size.x - LOT_GAP) * 0.5 if rng.randf() < 0.5 else 0.0
		if half > 0.0:
			out.append(Rect2(a, Vector2(half, size.y)))
			out.append(Rect2(a + Vector2(half + LOT_GAP, 0), Vector2(half, size.y)))
		else:
			var hz := (size.y - LOT_GAP) * 0.5
			out.append(Rect2(a, Vector2(size.x, hz)))
			out.append(Rect2(a + Vector2(0, hz + LOT_GAP), Vector2(size.x, hz)))
	else:
		var q := (size - Vector2.ONE * LOT_GAP) * 0.5
		for j in 2:
			for i in 2:
				out.append(Rect2(a + Vector2(i, j) * (q + Vector2.ONE * LOT_GAP), q))
	return out


func _tint(style: int) -> Color:
	match style:
		0: return Color(0.75, 0.9, 1.0).lerp(Color(0.85, 1.0, 0.9), rng.randf())
		1: return Color(0.42, 0.41, 0.39).lerp(Color(0.55, 0.53, 0.5), rng.randf())
		2: return Color(0.32, 0.15, 0.1).lerp(Color(0.5, 0.38, 0.28), rng.randf())
		3: return Color(0.18, 0.2, 0.22).lerp(Color(0.3, 0.3, 0.3), rng.randf())
		4: return Color(0.55, 0.52, 0.47).lerp(Color(0.68, 0.66, 0.62), rng.randf())
	return Color(0.5, 0.5, 0.5)


func _downtown_block(bmin: Vector2, bmax: Vector2, ground: float, bc: Vector2, c: Dictionary) -> void:
	var focus: Vector2 = WorldLayout.SKYLINE_FOCUS if c.name == "Port Calder" else c.center
	var falloff: float = 1500.0 if c.name == "Port Calder" else 700.0
	var t := clampf(1.0 - bc.distance_to(focus) / falloff, 0.0, 1.0)
	var max_h: float = 320.0 if c.name == "Port Calder" else 150.0
	for lot in _lots(bmin, bmax, Vector3(0.35, 0.4, 0.25)):
		var h := lerpf(55.0, max_h, pow(t, 1.2)) * rng.randf_range(0.55, 1.2)
		var slender := minf(lot.size.x, lot.size.y) * 7.0
		h = clampf(h, 30.0, slender)
		if c.name == "Port Calder" and t > 0.55 and rng.randf() < 0.07 and minf(lot.size.x, lot.size.y) > 55.0:
			h = rng.randf_range(300.0, 350.0)
		_tower(lot, ground, h)


func _tower(lot: Rect2, ground: float, h: float) -> void:
	building_count += 1
	var seed_v := rng.randf() * 100.0
	var kind := rng.randi() % 4
	var glass_style := 0 if rng.randf() < 0.6 else 3
	var masonry_style := 1 if rng.randf() < 0.5 else 4
	var center := lot.get_center()
	var y0 := ground - 3.0
	var top := ground + h
	var top_rect := lot
	if h > 250.0:
		kind = 1   # supertalls get setbacks and a spire
	match kind:
		0:
			# Single glass prism with a recessed crown.
			var st := Vector2(glass_style, seed_v)
			main.add_block(center, lot.size, y0, top, st, _tint(glass_style), ground)
		1:
			# Setback tower: up to four tiers.
			var tiers := rng.randi_range(2, 4)
			var style := masonry_style if rng.randf() < 0.45 else glass_style
			var col := _tint(style)
			var size := lot.size
			var yb := y0
			for k in tiers:
				var yt := ground + h * float(k + 1) / tiers
				if k < tiers - 1:
					yt = ground + h * float(k + 1) / tiers * rng.randf_range(0.85, 1.0)
				main.add_block(center, size, yb, yt, Vector2(style, seed_v), col, ground)
				top_rect = Rect2(center - size * 0.5, size)
				top = yt
				yb = yt
				size *= rng.randf_range(0.72, 0.85)
				size = size.max(Vector2(14, 14))
		2:
			# Podium with a slender tower.
			var ph := rng.randf_range(14.0, 26.0)
			main.add_block(center, lot.size, y0, ground + ph, Vector2(masonry_style, seed_v), _tint(masonry_style), ground)
			var ts := lot.size * rng.randf_range(0.55, 0.75)
			main.add_block(center, ts, ground + ph, top, Vector2(glass_style, seed_v), _tint(glass_style), ground)
			top_rect = Rect2(center - ts * 0.5, ts)
		3:
			# Octagonal glass tower on a short base.
			var r := minf(lot.size.x, lot.size.y) * 0.5
			main.add_block(center, lot.size, y0, ground + 6.0, Vector2(masonry_style, seed_v), _tint(masonry_style), ground)
			main.add_prism(center, r / cos(PI / 8.0) * 0.98, 8, ground + 6.0, top, Vector2(glass_style, seed_v), _tint(glass_style), ground)
			top_rect = Rect2(center - Vector2.ONE * r * 0.7, Vector2.ONE * r * 1.4)
	_roof(top_rect, top, h, seed_v, kind != 3)
	if h > 250.0:
		var sh := rng.randf_range(30.0, 60.0)
		detail.add_block(center, Vector2(2.5, 2.5), top, top + sh, Vector2(8, seed_v), Color(0.7, 0.72, 0.75), ground)
		obstacle_lights.append(Vector3(center.x, top + sh + 1.0, center.y))
	elif h > 120.0:
		obstacle_lights.append(Vector3(top_rect.position.x + 1.0, top + 1.0, top_rect.position.y + 1.0))
		obstacle_lights.append(Vector3(top_rect.end.x - 1.0, top + 1.0, top_rect.end.y - 1.0))


## Rooftop plant inside the central 60 % of the roof; records a clear roof probe at a corner.
func _roof(r: Rect2, top: float, h: float, seed_v: float, probe: bool) -> void:
	var c := r.get_center()
	var inner := r.size * 0.6
	var units := rng.randi_range(1, 3)
	for k in units:
		var s := Vector2(rng.randf_range(4.0, inner.x * 0.5), rng.randf_range(4.0, inner.y * 0.5)).min(inner)
		var off := Vector2(rng.randf_range(-1, 1), rng.randf_range(-1, 1)) * (inner - s) * 0.5
		detail.add_block(c + off, s, top, top + rng.randf_range(2.5, 6.0), Vector2(8, seed_v + k), Color(0.45, 0.46, 0.47), top)
	if probe and roof_probes.size() < 400 and h > 40.0:
		roof_probes.append(Vector3(r.position.x + 1.5, top, r.position.y + 1.5))


func _midrise_block(bmin: Vector2, bmax: Vector2, ground: float, frac: float) -> void:
	var hmax := lerpf(75.0, 22.0, clampf(frac, 0.0, 1.0))
	if rng.randf() < 0.3:
		# Perimeter block around a courtyard.
		building_count += 1
		var style := 2 if rng.randf() < 0.5 else 4
		var col := _tint(style)
		var seed_v := rng.randf() * 100.0
		var a := bmin + Vector2.ONE * SIDEWALK
		var b := bmax - Vector2.ONE * SIDEWALK
		var depth := 18.0
		var h := ground + rng.randf_range(16.0, hmax)
		main.add_block(Vector2((a.x + b.x) * 0.5, a.y + depth * 0.5), Vector2(b.x - a.x, depth), ground - 3.0, h, Vector2(style, seed_v), col, ground)
		main.add_block(Vector2((a.x + b.x) * 0.5, b.y - depth * 0.5), Vector2(b.x - a.x, depth), ground - 3.0, h, Vector2(style, seed_v), col, ground)
		main.add_block(Vector2(a.x + depth * 0.5, (a.y + b.y) * 0.5), Vector2(depth, b.y - a.y - depth * 2.0), ground - 3.0, h, Vector2(style, seed_v), col, ground)
		main.add_block(Vector2(b.x - depth * 0.5, (a.y + b.y) * 0.5), Vector2(depth, b.y - a.y - depth * 2.0), ground - 3.0, h, Vector2(style, seed_v), col, ground)
		return
	for lot in _lots(bmin, bmax, Vector3(0.55, 0.35, 0.1)):
		if rng.randf() < 0.25:
			continue
		building_count += 1
		var style: int = [1, 2, 4, 0][rng.randi() % 4]
		var h := rng.randf_range(12.0, hmax)
		var seed_v := rng.randf() * 100.0
		main.add_block(lot.get_center(), lot.size, ground - 3.0, ground + h, Vector2(style, seed_v), _tint(style), ground)
		_roof(lot, ground + h, h, seed_v, true)


## Sparse larger buildings among the (terrain-shaded) houses; they follow the terrain.
func _suburb_block(bmin: Vector2, bmax: Vector2) -> void:
	if rng.randf() > 0.07:
		return
	var a := bmin + Vector2.ONE * 12.0
	var b := bmax - Vector2.ONE * 12.0
	var size := Vector2(rng.randf_range(25.0, b.x - a.x), rng.randf_range(18.0, minf(45.0, b.y - a.y)))
	var c := Vector2(rng.randf_range(a.x + size.x * 0.5, b.x - size.x * 0.5), rng.randf_range(a.y + size.y * 0.5, b.y - size.y * 0.5))
	var lo := INF
	var hi := -INF
	for p in [c - size * 0.5, c + size * 0.5, c + Vector2(size.x, -size.y) * 0.5, c + Vector2(-size.x, size.y) * 0.5]:
		var h := terrain.height_at(p.x, p.y)
		lo = minf(lo, h)
		hi = maxf(hi, h)
	if lo < 2.0 or hi - lo > 6.0:
		return
	building_count += 1
	var style: int = [2, 4, 1][rng.randi() % 3]
	var height := rng.randf_range(7.0, 16.0)
	main.add_block(c, size, lo - 2.0, hi + height, Vector2(style, rng.randf() * 100.0), _tint(style), lo)


func _street_lights(c: Dictionary, kx0: int, kx1: int, kz0: int, kz1: int) -> void:
	var go := WorldLayout.GRID_ORIGIN
	var center: Vector2 = c.center
	var reach: float = c.suburb
	for axis in 2:
		var k0 := kx0 if axis == 0 else kz0
		var k1 := kx1 if axis == 0 else kz1
		for k in range(k0, k1 + 1):
			var line := line_pos(go.x if axis == 0 else go.y, k)
			var span0 := (center.y if axis == 0 else center.x) - reach
			var span1 := (center.y if axis == 0 else center.x) + reach
			var s := span0
			while s < span1:
				var p := Vector2(line, s) if axis == 0 else Vector2(s, line)
				var dist := p.distance_to(center)
				var core: bool = dist < c.core
				var step := 40.0 if core else 65.0
				s += step
				if dist > reach:
					continue
				var off := (line_width(k) * 0.5 - 2.0) if core else 8.0
				for side in ([-1.0, 1.0] if core else [1.0]):
					var q := p + (Vector2(off * side, 0) if axis == 0 else Vector2(0, off * side))
					var h := terrain.height_at(q.x, q.y)
					if h < 2.0:
						continue
					if not _block_allowed(q - Vector2.ONE, q + Vector2.ONE):
						continue
					street_lights.append(Vector3(q.x, h + 9.0, q.y))
