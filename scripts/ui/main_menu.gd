class_name MainMenu
extends Control
## Mode, aircraft, departure/destination and time-of-day selection.

signal start_requested(cfg: Dictionary)
signal quit_requested

const MODES := [
	["free", "Free Flight", "Fly anywhere: take off from any airport or start airborne over Port Calder. Thread the skyscrapers, dive under the bridge, chain stunts for points. Airline traffic shares the sky."],
	["dogfight", "Dogfight", "F-16 only. Endless waves of aggressor fighters over the city with your wingman. Cannon, heat-seekers, flares. Real damage: lose a wing and you will know it."],
	["skyline", "Skyline Run", "Timed ring course through the downtown street canyons and under the Strait bridge. Try it in the airliner if you dare."],
	["route", "Cross-Country", "Take off, fly to another airport, land and stop on the runway. Rated on your touchdown."],
	["landing", "Landing Challenge", "Start on a 3° final approach with a random crosswind. Butter it."],
]

var world: World
var cfg := {"mode": "free", "aircraft": "f16", "spawn": "air", "from": 0, "to": 1, "time": "noon"}

var _mode_buttons := {}
var _ac_buttons := {}
var _desc: Label
var _loc_box: VBoxContainer
var _time_opt: OptionButton
var _records: Label
var _controls_panel: PanelContainer
var _ac_info: Label


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	theme = UiTheme.make()
	var saved_time = GameMode.load_value("time_of_day", "noon")
	cfg.time = saved_time
	cfg.aircraft = GameMode.load_value("last_aircraft", "f16")

	var panel := PanelContainer.new()
	panel.position = Vector2(36, 36)
	panel.custom_minimum_size = Vector2(500, 0)
	add_child(panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	panel.add_child(v)
	v.add_child(UiTheme.label("SKYBREAK", 58, Color(1, 1, 1)))
	v.add_child(UiTheme.label("flight simulator", 18, Color(UiTheme.ACCENT, 0.9)))
	v.add_child(HSeparator.new())

	v.add_child(UiTheme.header("MODE"))
	var mg := ButtonGroup.new()
	var mode_grid := GridContainer.new()
	mode_grid.columns = 2
	v.add_child(mode_grid)
	for m in MODES:
		var b := Button.new()
		b.text = m[1]
		b.toggle_mode = true
		b.button_group = mg
		b.custom_minimum_size = Vector2(225, 38)
		b.pressed.connect(_on_mode.bind(m[0]))
		mode_grid.add_child(b)
		_mode_buttons[m[0]] = b
	_desc = UiTheme.label("", 15, Color(0.8, 0.84, 0.9))
	_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_desc.custom_minimum_size = Vector2(456, 64)
	v.add_child(_desc)

	v.add_child(UiTheme.header("AIRCRAFT"))
	var ag := ButtonGroup.new()
	var ah := HBoxContainer.new()
	v.add_child(ah)
	for id in AircraftSpec.TYPES:
		var b := Button.new()
		b.text = "F-16C Fighting Falcon" if id == "f16" else "Airliner (A320-class)"
		b.toggle_mode = true
		b.button_group = ag
		b.custom_minimum_size = Vector2(225, 40)
		b.pressed.connect(_on_aircraft.bind(id))
		ah.add_child(b)
		_ac_buttons[id] = b
	_ac_info = UiTheme.label("", 14, Color(0.75, 0.8, 0.86))
	_ac_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_ac_info.custom_minimum_size = Vector2(456, 40)
	v.add_child(_ac_info)

	_loc_box = VBoxContainer.new()
	v.add_child(_loc_box)

	v.add_child(UiTheme.header("TIME OF DAY"))
	_time_opt = OptionButton.new()
	for t in ["dawn", "noon", "sunset", "night"]:
		_time_opt.add_item(t.capitalize())
	_time_opt.selected = ["dawn", "noon", "sunset", "night"].find(cfg.time)
	_time_opt.item_selected.connect(func(i): cfg.time = ["dawn", "noon", "sunset", "night"][i])
	v.add_child(_time_opt)

	v.add_child(HSeparator.new())
	var fly := Button.new()
	fly.text = "FLY"
	fly.custom_minimum_size = Vector2(0, 54)
	fly.add_theme_font_size_override("font_size", 26)
	fly.pressed.connect(_on_fly)
	v.add_child(fly)
	var bh := HBoxContainer.new()
	v.add_child(bh)
	var cb := Button.new()
	cb.text = "Controls"
	cb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cb.pressed.connect(func(): _controls_panel.visible = not _controls_panel.visible)
	bh.add_child(cb)
	var qb := Button.new()
	qb.text = "Quit"
	qb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	qb.pressed.connect(func(): quit_requested.emit())
	bh.add_child(qb)

	_records = UiTheme.label("", 15, Color(0.85, 0.88, 0.92))
	var rp := PanelContainer.new()
	rp.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	rp.position = Vector2(-340, -190)
	rp.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	rp.grow_vertical = Control.GROW_DIRECTION_BEGIN
	rp.anchor_left = 1.0
	rp.anchor_top = 1.0
	rp.anchor_right = 1.0
	rp.anchor_bottom = 1.0
	rp.offset_left = -330
	rp.offset_top = -180
	rp.offset_right = -30
	rp.offset_bottom = -30
	var rv := VBoxContainer.new()
	rp.add_child(rv)
	rv.add_child(UiTheme.header("RECORDS"))
	rv.add_child(_records)
	add_child(rp)

	_controls_panel = PanelContainer.new()
	_controls_panel.position = Vector2(580, 36)
	var cv := VBoxContainer.new()
	_controls_panel.add_child(cv)
	cv.add_child(UiTheme.header("CONTROLS"))
	cv.add_child(UiTheme.controls_grid())
	_controls_panel.visible = false
	add_child(_controls_panel)

	_on_mode("free")
	(_mode_buttons["free"] as Button).button_pressed = true
	(_ac_buttons[cfg.aircraft] as Button).button_pressed = true
	_on_aircraft(cfg.aircraft)


func refresh() -> void:
	var lines := []
	var f16t: float = GameMode.load_value("skyline_best_f16", 0.0)
	var alt: float = GameMode.load_value("skyline_best_airliner", 0.0)
	lines.append("Skyline Run (F-16): %s" % (GameMode.fmt_time(f16t) if f16t > 0.0 else "--"))
	lines.append("Skyline Run (Airliner): %s" % (GameMode.fmt_time(alt) if alt > 0.0 else "--"))
	lines.append("Dogfight best score: %d" % int(GameMode.load_value("dogfight_best", 0)))
	lines.append("Best landing: %d / 1000" % int(GameMode.load_value("landing_best", 0)))
	_records.text = "\n".join(lines)


func _on_mode(id: String) -> void:
	cfg.mode = id
	for m in MODES:
		if m[0] == id:
			_desc.text = m[2]
	var airliner_ok := id != "dogfight"
	(_ac_buttons["airliner"] as Button).disabled = not airliner_ok
	if not airliner_ok and cfg.aircraft == "airliner":
		cfg.aircraft = "f16"
		(_ac_buttons["f16"] as Button).button_pressed = true
		_on_aircraft("f16")
	_build_location()


func _on_aircraft(id: String) -> void:
	cfg.aircraft = id
	var s := AircraftSpec.get_spec(id)
	if id == "f16":
		_ac_info.text = "%s. 11.8 t, 129 kN with afterburner, Mach 2 class, 9 G, M61 cannon, 6 heat-seekers, flares." % s.role
	else:
		_ac_info.text = "%s. 64 t, 2 x 120 kN turbofans, flight-envelope protection (P to disable at your own risk)." % s.role


func _build_location() -> void:
	for c in _loc_box.get_children():
		c.queue_free()
	if world == null:
		return
	var airports := world.airports
	match String(cfg.mode):
		"free":
			_loc_box.add_child(UiTheme.header("START"))
			var o := OptionButton.new()
			o.add_item("Airborne over Port Calder")
			for i in airports.size():
				o.add_item("Runway: %s (%s)" % [airports[i].name, airports[i].code])
			o.item_selected.connect(func(i): cfg.spawn = "air" if i == 0 else "runway:%d" % (i - 1))
			cfg.spawn = "air"
			_loc_box.add_child(o)
		"route":
			_loc_box.add_child(UiTheme.header("FROM  /  TO"))
			var h := HBoxContainer.new()
			_loc_box.add_child(h)
			var a := OptionButton.new()
			var b := OptionButton.new()
			for i in airports.size():
				a.add_item("%s (%s)" % [airports[i].name, airports[i].code])
				b.add_item("%s (%s)" % [airports[i].name, airports[i].code])
			a.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			cfg.from = 0
			cfg.to = mini(1, airports.size() - 1)
			a.selected = cfg.from
			b.selected = cfg.to
			a.item_selected.connect(func(i): cfg.from = i)
			b.item_selected.connect(func(i): cfg.to = i)
			h.add_child(a)
			h.add_child(b)
		"landing":
			_loc_box.add_child(UiTheme.header("AIRPORT"))
			var o2 := OptionButton.new()
			for i in airports.size():
				o2.add_item("%s (%s), %d m runway" % [airports[i].name, airports[i].code, int(airports[i].length)])
			cfg.to = 0
			o2.item_selected.connect(func(i): cfg.to = i)
			_loc_box.add_child(o2)


func _on_fly() -> void:
	Sfx.play("click", -6.0)
	GameMode.save_value("time_of_day", cfg.time)
	GameMode.save_value("last_aircraft", cfg.aircraft)
	start_requested.emit(cfg.duplicate())
