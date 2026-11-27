class_name Bullets
extends Node3D
## All cannon rounds in flight: ballistic, ray-swept each physics step, drawn as tracers with one MultiMesh.

static var instance: Bullets

const MAX_ROUNDS := 500
const LIFE := 2.6

var _pos := PackedVector3Array()
var _vel := PackedVector3Array()
var _life := PackedFloat32Array()
var _dmg := PackedFloat32Array()
var _owner: Array = []
var _mm: MultiMesh
var _fx_budget := 0.0


func _enter_tree() -> void:
	instance = self


func _exit_tree() -> void:
	if instance == self:
		instance = null


func _ready() -> void:
	_mm = MultiMesh.new()
	_mm.transform_format = MultiMesh.TRANSFORM_3D
	_mm.instance_count = MAX_ROUNDS
	_mm.visible_instance_count = 0
	var bm := BoxMesh.new()
	bm.size = Vector3(0.09, 0.09, 1.0)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1.0, 0.75, 0.35)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.6, 0.25)
	mat.emission_energy_multiplier = 6.0
	bm.material = mat
	_mm.mesh = bm
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = _mm
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mmi.custom_aabb = AABB(Vector3(-30000, -2000, -30000), Vector3(60000, 20000, 60000))
	add_child(mmi)


func fire(origin: Vector3, velocity: Vector3, shooter: Node, damage: float) -> void:
	if _pos.size() >= MAX_ROUNDS:
		_remove(0)
	_pos.append(origin)
	_vel.append(velocity)
	_life.append(LIFE)
	_dmg.append(damage)
	_owner.append(shooter)


func clear() -> void:
	_pos.clear()
	_vel.clear()
	_life.clear()
	_dmg.clear()
	_owner.clear()
	_mm.visible_instance_count = 0


func _remove(i: int) -> void:
	var last := _pos.size() - 1
	_pos[i] = _pos[last]
	_vel[i] = _vel[last]
	_life[i] = _life[last]
	_dmg[i] = _dmg[last]
	_owner[i] = _owner[last]
	_pos.resize(last)
	_vel.resize(last)
	_life.resize(last)
	_dmg.resize(last)
	_owner.resize(last)


func _physics_process(dt: float) -> void:
	_fx_budget = minf(_fx_budget + dt * 25.0, 6.0)
	var space := get_world_3d().direct_space_state
	var world := World.instance
	var i := 0
	while i < _pos.size():
		_life[i] -= dt
		var p := _pos[i]
		var v := _vel[i]
		v.y -= 9.81 * dt
		v *= 1.0 - 0.06 * dt # supersonic round drag (rough)
		var np := p + v * dt
		var q := PhysicsRayQueryParameters3D.create(p, np, 1 | 2)
		var shooter = _owner[i]
		if shooter != null and is_instance_valid(shooter) and shooter is CollisionObject3D:
			q.exclude = [(shooter as CollisionObject3D).get_rid()]
		var hit := space.intersect_ray(q)
		if not hit.is_empty():
			var col = hit.collider
			if col is Aircraft:
				(col as Aircraft).take_hit(hit.position, _dmg[i], shooter if is_instance_valid(shooter) else null, hit.shape)
			elif _fx_budget >= 1.0:
				_fx_budget -= 1.0
				Fx.impact(get_parent(), hit.position, hit.normal)
			_remove(i)
			continue
		if world != null and np.y < 0.0 and world.is_over_water(np.x, np.z):
			if _fx_budget >= 1.0:
				_fx_budget -= 1.0
				Fx.impact(get_parent(), Vector3(np.x, 0.0, np.z), Vector3.UP, true)
			_remove(i)
			continue
		if _life[i] <= 0.0:
			_remove(i)
			continue
		_pos[i] = np
		_vel[i] = v
		i += 1


func _process(_delta: float) -> void:
	var n := _pos.size()
	_mm.visible_instance_count = n
	for i in n:
		var v := _vel[i]
		var sp := v.length()
		if sp < 1.0:
			continue
		var dir := v / sp
		var length := clampf(sp * 0.012, 4.0, 14.0)
		var up := Vector3.UP if absf(dir.y) < 0.95 else Vector3.RIGHT
		var basis := Basis.looking_at(dir, up).scaled_local(Vector3(1, 1, length))
		_mm.set_instance_transform(i, Transform3D(basis, _pos[i] - dir * length * 0.5))
