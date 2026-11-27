class_name WorldBridge
extends RefCounted
## Suspension bridge across the strait at BRIDGE_Z: concrete towers on footings, steel deck box, main and
## side-span cables with suspenders, anchorages and descending approach viaducts on both banks.

const TOWER_OFF := 450.0
const ANCHOR_OFF := 800.0
const DECK_TOP := 67.0
const DECK_THICK := 6.0
const DECK_W := 32.0
const TOWER_TOP := 182.0
const LEG_Z := 21.0
const CABLE_Z := 18.0
const CABLE_LOW := 72.0
const RAMP_LEN := 1100.0
const SEG := 100.0

var layout: WorldLayout
var terrain: WorldTerrain
var batch: GeoBatch
var xc := 0.0
var z0 := 0.0
var obstacle_lights: Array[Vector3] = []
var deck_lights: Array[Vector3] = []
var gate: Dictionary = {}

var _steel := Vector2(7, 3.0)
var _steel_col := Color(0.55, 0.58, 0.6)
var _concrete := Vector2(5, 4.0)
var _concrete_col := Color(0.6, 0.59, 0.56)


func _init(p_layout: WorldLayout, p_terrain: WorldTerrain, p_batch: GeoBatch) -> void:
	layout = p_layout
	terrain = p_terrain
	batch = p_batch
	z0 = WorldLayout.BRIDGE_Z
	xc = layout.strait_x(z0)


func build() -> void:
	var deck_bottom := DECK_TOP - DECK_THICK
	# Main and side span deck.
	var x := xc - ANCHOR_OFF
	while x < xc + ANCHOR_OFF - 0.1:
		var seg_l := minf(SEG, xc + ANCHOR_OFF - x)
		batch.add_box(Transform3D(Basis.IDENTITY, Vector3(x + seg_l * 0.5, DECK_TOP - DECK_THICK * 0.5, z0)),
			Vector3(seg_l, DECK_THICK, DECK_W), _steel, _steel_col, 0.0, true, true, true)
		x += seg_l
	# Approach viaducts.
	for side in [-1.0, 1.0]:
		var start: float = xc + side * ANCHOR_OFF
		var end_x: float = start + side * RAMP_LEN
		var end_y := terrain.height_at(end_x, z0) + 0.3
		var segs := int(RAMP_LEN / SEG)
		for k in segs:
			var xa: float = start + side * k * SEG
			var xb: float = xa + side * SEG
			var ya := lerpf(DECK_TOP, end_y, float(k) / segs)
			var yb := lerpf(DECK_TOP, end_y, float(k + 1) / segs)
			var mid := Vector3((xa + xb) * 0.5, (ya + yb) * 0.5 - DECK_THICK * 0.4, z0)
			var ang := atan2(yb - ya, xb - xa)
			if side < 0.0:
				ang = atan2(ya - yb, xa - xb)
			var basis := Basis(Vector3.BACK, ang)
			var seg_len := Vector2(SEG, yb - ya).length() + 0.5
			batch.add_box(Transform3D(basis, mid), Vector3(seg_len, DECK_THICK * 0.8, DECK_W - 4.0), _concrete, _concrete_col, 0.0, true, true, true)
			# Piers.
			var ground := terrain.height_at(xb, z0)
			var top := yb - DECK_THICK * 0.8
			if top - ground > 3.0:
				for pz in [-8.0, 8.0]:
					batch.add_block(Vector2(xb, z0 + pz), Vector2(3.5, 3.5), ground - 3.0, top, _concrete, _concrete_col, ground)
		# Anchorage.
		var ga := terrain.height_at(start, z0)
		batch.add_block(Vector2(start + side * 10.0, z0), Vector2(60.0, 52.0), ga - 6.0, DECK_TOP + 6.0, _concrete, _concrete_col, ga)
	# Towers.
	for side in [-1.0, 1.0]:
		var tx: float = xc + side * TOWER_OFF
		batch.add_block(Vector2(tx, z0), Vector2(30.0, 62.0), -12.0, 6.0, _concrete, _concrete_col, -12.0)
		for lz in [-LEG_Z, LEG_Z]:
			batch.add_block(Vector2(tx, z0 + lz), Vector2(10.0, 9.0), 6.0, 110.0, _concrete, _concrete_col, 6.0)
			batch.add_block(Vector2(tx, z0 + lz), Vector2(8.0, 7.0), 110.0, TOWER_TOP, _concrete, _concrete_col, 6.0)
		for beam in [[deck_bottom - 7.0, deck_bottom - 1.0], [124.0, 131.0], [TOWER_TOP - 7.0, TOWER_TOP]]:
			batch.add_block(Vector2(tx, z0), Vector2(8.0, LEG_Z * 2.0), beam[0], beam[1], _concrete, _concrete_col, 6.0)
		obstacle_lights.append(Vector3(tx, TOWER_TOP + 1.5, z0 - LEG_Z))
		obstacle_lights.append(Vector3(tx, TOWER_TOP + 1.5, z0 + LEG_Z))
	# Cables and suspenders.
	for cz in [-CABLE_Z, CABLE_Z]:
		_cable_span(xc - TOWER_OFF, xc + TOWER_OFF, cz, true)
		_cable_span(xc - ANCHOR_OFF, xc - TOWER_OFF, cz, false)
		_cable_span(xc + TOWER_OFF, xc + ANCHOR_OFF, cz, false)
	# Deck lamps.
	var lx := xc - ANCHOR_OFF - RAMP_LEN
	while lx < xc + ANCHOR_OFF + RAMP_LEN:
		var y := _deck_y(lx) + 9.0
		deck_lights.append(Vector3(lx, y, z0 - DECK_W * 0.5 + 1.0))
		deck_lights.append(Vector3(lx, y, z0 + DECK_W * 0.5 - 1.0))
		lx += 50.0
	gate = {
		"center": Vector3(xc, deck_bottom * 0.5, z0),
		"basis": Basis(Vector3.UP, PI),   # -Z points south, down the channel toward the sea
		"size": Vector2(TOWER_OFF * 2.0 - 30.0, deck_bottom),
	}


func _deck_y(x: float) -> float:
	var d := absf(x - xc) - ANCHOR_OFF
	if d <= 0.0:
		return DECK_TOP
	return lerpf(DECK_TOP, terrain.height_at(xc + signf(x - xc) * (ANCHOR_OFF + RAMP_LEN), z0), clampf(d / RAMP_LEN, 0.0, 1.0))


func cable_y(x: float, main: bool) -> float:
	if main:
		var t := (x - xc) / TOWER_OFF
		return CABLE_LOW + (TOWER_TOP - CABLE_LOW) * t * t
	var t := (absf(x - xc) - TOWER_OFF) / (ANCHOR_OFF - TOWER_OFF)
	return lerpf(TOWER_TOP, DECK_TOP + 5.0, t) - 12.0 * 4.0 * t * (1.0 - t)


func _cable_span(xa: float, xb: float, cz: float, main: bool) -> void:
	var n := int((xb - xa) / 15.0)
	var prev := Vector3(xa, cable_y(xa, main), z0 + cz)
	for k in range(1, n + 1):
		var x := lerpf(xa, xb, float(k) / n)
		var p := Vector3(x, cable_y(x, main), z0 + cz)
		var dir := p - prev
		var seg_l := dir.length()
		var bx := dir / seg_l
		var bz := bx.cross(Vector3.UP).normalized()
		var by := bz.cross(bx)
		batch.add_box(Transform3D(Basis(bx, by, bz), (p + prev) * 0.5), Vector3(seg_l + 0.3, 1.1, 1.1), _steel, _steel_col, 0.0, true, true, true)
		if k < n:
			var hang := p.y - DECK_TOP
			if hang > 1.5:
				batch.add_block(Vector2(x, z0 + cz), Vector2(0.4, 0.4), DECK_TOP, p.y, _steel, _steel_col, DECK_TOP)
		prev = p
