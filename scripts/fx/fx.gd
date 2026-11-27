class_name Fx
extends RefCounted
## Particle effects: explosions, smoke/fire trails, sparks, impacts. All procedural.

static var light_level := 1.0 # set from time of day: scales smoke brightness so it is not glowing at night
static var _soft: Texture2D
static var _mats := {}
static var _meshes := {}


static func soft_texture() -> Texture2D:
	if _soft == null:
		var g := Gradient.new()
		g.set_color(0, Color(1, 1, 1, 1))
		g.set_color(1, Color(1, 1, 1, 0))
		g.add_point(0.45, Color(1, 1, 1, 0.55))
		var t := GradientTexture2D.new()
		t.gradient = g
		t.fill = GradientTexture2D.FILL_RADIAL
		t.fill_from = Vector2(0.5, 0.5)
		t.fill_to = Vector2(1.0, 0.5)
		t.width = 64
		t.height = 64
		_soft = t
	return _soft


static func _billboard_mat(additive: bool) -> StandardMaterial3D:
	var key := "add" if additive else "alpha"
	if _mats.has(key):
		return _mats[key]
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	m.billboard_keep_scale = true
	m.vertex_color_use_as_albedo = true
	m.albedo_texture = soft_texture()
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD if additive else BaseMaterial3D.BLEND_MODE_MIX
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.disable_receive_shadows = true
	_mats[key] = m
	return m


static func _quad(additive: bool) -> QuadMesh:
	var key := "q_add" if additive else "q_alpha"
	if not _meshes.has(key):
		var q := QuadMesh.new()
		q.size = Vector2(1, 1)
		q.material = _billboard_mat(additive)
		_meshes[key] = q
	return _meshes[key]


static func _curve(points: Array) -> CurveTexture:
	var c := Curve.new()
	c.max_value = 4.0
	for p in points:
		c.add_point(p)
	var t := CurveTexture.new()
	t.curve = c
	return t


static func _ramp(colors: Array, offsets: Array) -> GradientTexture1D:
	var g := Gradient.new()
	g.colors = PackedColorArray(colors)
	g.offsets = PackedFloat32Array(offsets)
	var t := GradientTexture1D.new()
	t.gradient = g
	return t


static func _particles(amount: int, lifetime: float, additive: bool) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.amount = amount
	p.lifetime = lifetime
	p.draw_pass_1 = _quad(additive)
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	p.visibility_aabb = AABB(Vector3(-400, -400, -400), Vector3(800, 800, 800))
	return p


static func _smoke_col(c: Color) -> Color:
	var l := clampf(light_level, 0.12, 1.0)
	return Color(c.r * l, c.g * l, c.b * l, c.a)


# ------------------------------------------------------------------ continuous emitters

## World-space smoke trail. density 0..1 (scales amount/opacity), dark: 0 white vapour .. 1 black oil smoke.
static func smoke_trail(size := 2.0, dark := 0.7, lifetime := 5.0) -> GPUParticles3D:
	var p := _particles(110, lifetime, false)
	p.local_coords = false
	p.fixed_fps = 30
	p.interpolate = true
	var m := ParticleProcessMaterial.new()
	m.direction = Vector3(0, 1, 0)
	m.spread = 25.0
	m.initial_velocity_min = 1.0
	m.initial_velocity_max = 4.0
	m.gravity = Vector3(0, 1.2, 0)
	m.damping_min = 0.5
	m.damping_max = 1.0
	m.scale_min = size * 0.6
	m.scale_max = size
	m.scale_curve = _curve([Vector2(0, 0.5), Vector2(0.3, 1.6), Vector2(1, 3.5)])
	var base := Color(0.08, 0.075, 0.07).lerp(Color(0.85, 0.85, 0.85), 1.0 - dark)
	m.color_ramp = _ramp([_smoke_col(Color(base, 0.0)), _smoke_col(Color(base, 0.55)), _smoke_col(Color(base.lightened(0.25), 0.3)), _smoke_col(Color(base.lightened(0.4), 0.0))],
		[0.0, 0.08, 0.5, 1.0])
	m.angle_min = -180.0
	m.angle_max = 180.0
	m.angular_velocity_min = -20.0
	m.angular_velocity_max = 20.0
	m.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	m.emission_sphere_radius = size * 0.2
	p.process_material = m
	return p


static func fire_emitter(size := 1.5) -> Node3D:
	var root := Node3D.new()
	var p := _particles(60, 0.7, true)
	p.local_coords = false
	p.fixed_fps = 30
	p.interpolate = true
	var m := ParticleProcessMaterial.new()
	m.direction = Vector3(0, 1, 0)
	m.spread = 30.0
	m.initial_velocity_min = 1.0
	m.initial_velocity_max = 3.0
	m.gravity = Vector3(0, 3.0, 0)
	m.scale_min = size * 0.6
	m.scale_max = size * 1.1
	m.scale_curve = _curve([Vector2(0, 0.6), Vector2(0.4, 1.0), Vector2(1, 0.2)])
	m.color_ramp = _ramp([Color(1.0, 0.95, 0.7, 1.0), Color(1.0, 0.55, 0.12, 0.9), Color(0.8, 0.18, 0.04, 0.5), Color(0.2, 0.05, 0.02, 0.0)],
		[0.0, 0.25, 0.6, 1.0])
	m.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	m.emission_sphere_radius = size * 0.3
	p.process_material = m
	root.add_child(p)
	var light := OmniLight3D.new()
	light.light_color = Color(1.0, 0.55, 0.2)
	light.light_energy = 2.5
	light.omni_range = size * 12.0
	light.shadow_enabled = false
	light.set_meta("flicker", true)
	root.add_child(light)
	var smoke := smoke_trail(size * 1.3, 0.95, 6.0)
	root.add_child(smoke)
	return root


## Wingtip vapour / condensation trail (thin, short).
static func vapor_trail() -> GPUParticles3D:
	var p := _particles(80, 0.9, false)
	p.local_coords = false
	p.fixed_fps = 60
	p.interpolate = true
	var m := ParticleProcessMaterial.new()
	m.spread = 2.0
	m.initial_velocity_min = 0.0
	m.initial_velocity_max = 0.5
	m.gravity = Vector3.ZERO
	m.scale_min = 0.35
	m.scale_max = 0.55
	m.scale_curve = _curve([Vector2(0, 0.5), Vector2(1, 2.2)])
	m.color_ramp = _ramp([Color(1, 1, 1, 0.0), Color(1, 1, 1, 0.45), Color(1, 1, 1, 0.0)], [0.0, 0.1, 1.0])
	p.process_material = m
	return p


## Missile motor plume: bright core + long white smoke.
static func missile_plume() -> Node3D:
	var root := Node3D.new()
	var flame := _particles(40, 0.12, true)
	flame.local_coords = false
	var fm := ParticleProcessMaterial.new()
	fm.direction = Vector3(0, 0, 1)
	fm.spread = 5.0
	fm.initial_velocity_min = 20.0
	fm.initial_velocity_max = 30.0
	fm.gravity = Vector3.ZERO
	fm.scale_min = 0.7
	fm.scale_max = 1.0
	fm.color_ramp = _ramp([Color(1, 1, 0.9, 1), Color(1, 0.6, 0.2, 0.6), Color(1, 0.3, 0.1, 0.0)], [0.0, 0.4, 1.0])
	flame.process_material = fm
	root.add_child(flame)
	var smoke := smoke_trail(1.4, 0.0, 7.0)
	smoke.amount = 260
	(smoke.process_material as ParticleProcessMaterial).initial_velocity_max = 1.0
	root.add_child(smoke)
	var light := OmniLight3D.new()
	light.light_color = Color(1, 0.7, 0.4)
	light.light_energy = 3.0
	light.omni_range = 25.0
	root.add_child(light)
	return root


# ------------------------------------------------------------------ one-shots

static func _auto_free(node: Node, seconds: float) -> void:
	node.get_tree().create_timer(seconds, false).timeout.connect(node.queue_free)


## Big fireball explosion with smoke column, sparks, debris and a flash.
static func explosion(parent: Node, pos: Vector3, size := 1.0, vel := Vector3.ZERO) -> void:
	if parent == null or not parent.is_inside_tree():
		return
	var root: Node3D = _ExplosionMover.new()
	parent.add_child(root)
	root.global_position = pos

	var fire := _particles(int(36 * clampf(size, 0.6, 2.5)), 1.4 * sqrt(size), true)
	fire.one_shot = true
	fire.explosiveness = 0.92
	var fm := ParticleProcessMaterial.new()
	fm.direction = Vector3(0, 1, 0)
	fm.spread = 180.0
	fm.initial_velocity_min = 6.0 * size
	fm.initial_velocity_max = 22.0 * size
	fm.damping_min = 8.0 * size
	fm.damping_max = 14.0 * size
	fm.gravity = Vector3(0, 4, 0)
	fm.scale_min = 7.0 * size
	fm.scale_max = 14.0 * size
	fm.scale_curve = _curve([Vector2(0, 0.35), Vector2(0.15, 1.0), Vector2(1, 1.5)])
	fm.color_ramp = _ramp([Color(1, 1, 0.85, 1), Color(1, 0.7, 0.25, 1), Color(0.95, 0.3, 0.05, 0.8), Color(0.25, 0.1, 0.05, 0.4), Color(0.05, 0.05, 0.05, 0.0)],
		[0.0, 0.12, 0.35, 0.7, 1.0])
	fm.angle_min = -180
	fm.angle_max = 180
	fm.inherit_velocity_ratio = 0.0
	fm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	fm.emission_sphere_radius = 2.0 * size
	fire.process_material = fm
	root.add_child(fire)

	var smoke := _particles(int(30 * clampf(size, 0.6, 2.5)), 9.0, false)
	smoke.one_shot = true
	smoke.explosiveness = 0.75
	var sm := ParticleProcessMaterial.new()
	sm.direction = Vector3(0, 1, 0)
	sm.spread = 70.0
	sm.initial_velocity_min = 3.0 * size
	sm.initial_velocity_max = 14.0 * size
	sm.damping_min = 2.0
	sm.damping_max = 4.0
	sm.gravity = Vector3(0, 2.5, 0)
	sm.scale_min = 10.0 * size
	sm.scale_max = 18.0 * size
	sm.scale_curve = _curve([Vector2(0, 0.4), Vector2(0.3, 1.2), Vector2(1, 2.6)])
	sm.color_ramp = _ramp([_smoke_col(Color(0.15, 0.12, 0.1, 0.0)), _smoke_col(Color(0.12, 0.11, 0.1, 0.75)), _smoke_col(Color(0.3, 0.3, 0.3, 0.4)), _smoke_col(Color(0.45, 0.45, 0.45, 0.0))],
		[0.0, 0.1, 0.55, 1.0])
	sm.angle_min = -180
	sm.angle_max = 180
	sm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	sm.emission_sphere_radius = 3.0 * size
	smoke.process_material = sm
	root.add_child(smoke)

	var sparks := _particles(int(70 * clampf(size, 0.5, 2.0)), 2.2, true)
	sparks.one_shot = true
	sparks.explosiveness = 1.0
	var spm := ParticleProcessMaterial.new()
	spm.direction = Vector3(0, 1, 0)
	spm.spread = 180.0
	spm.initial_velocity_min = 25.0 * size
	spm.initial_velocity_max = 70.0 * size
	spm.gravity = Vector3(0, -9.8, 0)
	spm.damping_min = 1.0
	spm.damping_max = 3.0
	spm.scale_min = 0.6
	spm.scale_max = 1.4
	spm.color_ramp = _ramp([Color(1, 0.9, 0.6, 1), Color(1, 0.5, 0.1, 1), Color(0.6, 0.1, 0.0, 0.0)], [0.0, 0.5, 1.0])
	sparks.process_material = spm
	root.add_child(sparks)

	# Burning debris chunks that arc out trailing smoke.
	var chunk_count := int(clampf(4.0 * size, 2.0, 9.0))
	for i in chunk_count:
		var d := _debris_chunk(size)
		root.add_child(d)
		var dir := Vector3(randf_range(-1, 1), randf_range(0.2, 1.3), randf_range(-1, 1)).normalized()
		d.set_meta("vel", vel * 0.6 + dir * randf_range(15.0, 45.0) * sqrt(size))

	var light := OmniLight3D.new()
	light.light_color = Color(1.0, 0.65, 0.3)
	light.light_energy = 16.0 * size
	light.omni_range = 120.0 * size
	light.omni_attenuation = 1.4
	root.add_child(light)
	var tw := root.create_tween()
	tw.tween_property(light, "light_energy", 0.0, 1.2)

	for c in root.get_children():
		if c is GPUParticles3D:
			(c as GPUParticles3D).emitting = true
	Sfx.play_at("explosion", pos, clampf(size, 0.4, 3.0))
	CameraRig.shake_at(pos, size)
	_auto_free(root, 11.0)


static func _debris_chunk(size: float) -> Node3D:
	var n := Node3D.new()
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(randf_range(0.3, 1.2), randf_range(0.1, 0.5), randf_range(0.3, 1.5)) * clampf(size, 0.5, 2.0)
	mi.mesh = bm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.1, 0.09, 0.08)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.35, 0.05)
	mat.emission_energy_multiplier = 1.5
	mi.material_override = mat
	n.add_child(mi)
	var trail := smoke_trail(1.1 * clampf(size, 0.5, 2.0), 0.9, 3.0)
	trail.emitting = true
	n.add_child(trail)
	return n


## Bullet impact on ground/building: dust + sparks. water=true gives a splash column.
static func impact(parent: Node, pos: Vector3, normal: Vector3, water := false) -> void:
	if parent == null or not parent.is_inside_tree():
		return
	var p := _particles(14 if not water else 18, 1.2 if not water else 1.6, false)
	p.one_shot = true
	p.explosiveness = 0.9
	var m := ParticleProcessMaterial.new()
	m.direction = normal
	m.spread = 25.0 if water else 40.0
	m.initial_velocity_min = 4.0
	m.initial_velocity_max = 14.0 if water else 9.0
	m.gravity = Vector3(0, -9.8, 0)
	m.scale_min = 1.2
	m.scale_max = 2.6
	m.scale_curve = _curve([Vector2(0, 0.5), Vector2(1, 1.8)])
	if water:
		m.color_ramp = _ramp([Color(0.9, 0.95, 1.0, 0.8), Color(0.9, 0.95, 1.0, 0.0)], [0.0, 1.0])
	else:
		m.color_ramp = _ramp([_smoke_col(Color(0.5, 0.44, 0.36, 0.8)), _smoke_col(Color(0.5, 0.45, 0.4, 0.0))], [0.0, 1.0])
	p.process_material = m
	parent.add_child(p)
	p.global_position = pos
	p.emitting = true
	_auto_free(p, 2.0)
	sparks(parent, pos, normal, 6)


static func sparks(parent: Node, pos: Vector3, normal: Vector3, count := 12) -> void:
	if parent == null or not parent.is_inside_tree():
		return
	var p := _particles(count, 0.5, true)
	p.one_shot = true
	p.explosiveness = 1.0
	var m := ParticleProcessMaterial.new()
	m.direction = normal
	m.spread = 60.0
	m.initial_velocity_min = 8.0
	m.initial_velocity_max = 30.0
	m.gravity = Vector3(0, -9.8, 0)
	m.scale_min = 0.25
	m.scale_max = 0.5
	m.color_ramp = _ramp([Color(1, 0.95, 0.7, 1), Color(1, 0.5, 0.1, 0.0)], [0.0, 1.0])
	p.process_material = m
	parent.add_child(p)
	p.global_position = pos
	p.emitting = true
	_auto_free(p, 1.0)


## Short-lived flash (muzzle / flare ignition).
static func flash(parent: Node, pos: Vector3, color := Color(1, 0.8, 0.4), energy := 4.0, rng := 18.0, time := 0.06) -> void:
	if parent == null or not parent.is_inside_tree():
		return
	var l := OmniLight3D.new()
	l.light_color = color
	l.light_energy = energy
	l.omni_range = rng
	parent.add_child(l)
	l.global_position = pos
	_auto_free(l, time)


## Moves debris chunks of an explosion ballistically (attached to the explosion root).
const _ExplosionMover := preload("res://scripts/fx/explosion_mover.gd")
