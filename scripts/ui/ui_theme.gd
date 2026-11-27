class_name UiTheme
extends RefCounted
## Shared look for menus: dark translucent panels, orange accent.

const ACCENT := Color(0.98, 0.58, 0.16)


static func make() -> Theme:
	var t := Theme.new()
	t.default_font_size = 18
	var normal := _box(Color(0.1, 0.12, 0.15, 0.88), Color(0.25, 0.28, 0.32))
	var hover := _box(Color(0.16, 0.19, 0.24, 0.95), Color(0.5, 0.55, 0.6))
	var pressed := _box(Color(ACCENT, 0.9), ACCENT.lightened(0.3))
	var disabled := _box(Color(0.08, 0.08, 0.09, 0.6), Color(0.15, 0.15, 0.15))
	for cls in ["Button", "OptionButton"]:
		t.set_stylebox("normal", cls, normal)
		t.set_stylebox("hover", cls, hover)
		t.set_stylebox("pressed", cls, pressed)
		t.set_stylebox("hover_pressed", cls, pressed)
		t.set_stylebox("disabled", cls, disabled)
		t.set_stylebox("focus", cls, _box(Color(0, 0, 0, 0), Color(ACCENT, 0.7)))
		t.set_color("font_color", cls, Color(0.92, 0.94, 0.97))
		t.set_color("font_pressed_color", cls, Color(0.05, 0.05, 0.05))
		t.set_color("font_hover_pressed_color", cls, Color(0.05, 0.05, 0.05))
		t.set_color("font_disabled_color", cls, Color(0.45, 0.45, 0.45))
	var panel := _box(Color(0.03, 0.04, 0.06, 0.78), Color(0.2, 0.22, 0.26))
	panel.content_margin_left = 22
	panel.content_margin_right = 22
	panel.content_margin_top = 18
	panel.content_margin_bottom = 18
	t.set_stylebox("panel", "PanelContainer", panel)
	t.set_color("font_color", "Label", Color(0.9, 0.93, 0.97))
	return t


static func _box(bg: Color, border: Color) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = border
	s.set_border_width_all(1)
	s.set_corner_radius_all(5)
	s.content_margin_left = 12
	s.content_margin_right = 12
	s.content_margin_top = 7
	s.content_margin_bottom = 7
	return s


static func label(text: String, size := 18, color := Color(0.9, 0.93, 0.97)) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l


static func header(text: String) -> Label:
	var l := label(text, 14, Color(ACCENT, 0.95))
	return l


static func controls_grid() -> GridContainer:
	var g := GridContainer.new()
	g.columns = 2
	g.add_theme_constant_override("h_separation", 28)
	g.add_theme_constant_override("v_separation", 4)
	for row in Controls.HELP:
		g.add_child(label(row[0], 16, ACCENT.lightened(0.2)))
		g.add_child(label(row[1], 16))
	return g
