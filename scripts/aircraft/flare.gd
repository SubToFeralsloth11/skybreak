class_name Flare
extends Node3D
## Magnesium decoy flare: burns bright for a few seconds while falling and slowing; missiles may chase it.

static var active: Array[Flare] = []

var vel := Vector3.ZERO
var age := 0.0
var lifetime := 4.5
var _light: OmniLight3D
var _core: MeshInstance3D


func launch(pos: Vector3, p_vel: Vector3, _owner: Node) -> void:
	global_position = pos
	vel = p_vel
	_core = MeshInstance3D.new()
	var q := QuadMesh.new()
	q.size = Vector2(4.5, 4.5)
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.albedo_texture = Fx.soft_texture()
	m.albedo_color = Color(1.0, 0.92, 0.75)
	q.material = m
	_core.mesh = q
	_core.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_core)
	_light = OmniLight3D.new()
	_light.light_color = Color(1.0, 0.85, 0.6)
	_light.light_energy = 5.0
	_light.omni_range = 60.0
	add_child(_light)
	var smoke := Fx.smoke_trail(1.6, 0.0, 4.0)
	smoke.emitting = true
	add_child(smoke)
	active.append(self)


func _exit_tree() -> void:
	active.erase(self)


func _physics_process(dt: float) -> void:
	age += dt
	vel.y -= 9.81 * dt
	vel -= vel * minf(dt * 1.4, 1.0)
	global_position += vel * dt
	var k := clampf(1.0 - age / lifetime, 0.0, 1.0)
	_light.light_energy = 5.0 * k * (0.8 + randf() * 0.4)
	_core.scale = Vector3.ONE * (0.4 + k * 0.6)
	if age > lifetime:
		active.erase(self)
		_core.visible = false
		_light.visible = false
		set_physics_process(false)
		for c in get_children():
			if c is GPUParticles3D:
				(c as GPUParticles3D).emitting = false
		get_tree().create_timer(4.0, false).timeout.connect(queue_free)
