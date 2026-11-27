class_name Debris
extends RigidBody3D
## A torn-off aircraft part: tumbles with crude aero drag, burns, and explodes when it hits the ground.

var _life := 45.0
var _impacted := false
var _flutter := Vector3.ZERO


func setup_from(part_node: Node3D, center_local: Vector3, vel: Vector3, ang: Vector3, p_mass: float) -> void:
	collision_layer = 4
	collision_mask = 1
	mass = maxf(p_mass, 80.0)
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = center_local
	linear_damp = 0.08
	angular_damp = 0.4
	contact_monitor = true
	max_contacts_reported = 2
	continuous_cd = true
	var aabb := AABB()
	var first := true
	for mi in part_node.find_children("*", "MeshInstance3D", true, false):
		var m := mi as MeshInstance3D
		var t := Transform3D.IDENTITY
		var c: Node = m
		while c != null and c != part_node:
			if c is Node3D:
				t = (c as Node3D).transform * t
			c = c.get_parent()
		var box := t * m.get_aabb()
		if first:
			aabb = box
			first = false
		else:
			aabb = aabb.merge(box)
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = aabb.size.max(Vector3(0.3, 0.3, 0.3))
	cs.shape = bs
	cs.position = aabb.get_center()
	add_child(cs)
	part_node.reparent(self, true)
	linear_velocity = vel
	angular_velocity = ang
	_flutter = Vector3(randf_range(-1, 1), randf_range(-1, 1), randf_range(-1, 1)) * mass * 6.0
	var trail := Fx.fire_emitter(1.4)
	trail.position = aabb.get_center()
	add_child(trail)
	body_entered.connect(_on_body_entered)


func _physics_process(delta: float) -> void:
	_life -= delta
	if _life <= 0.0:
		queue_free()
		return
	# Tumbling plate: quadratic drag + flutter torque.
	var v := linear_velocity
	var sp := v.length()
	if sp > 1.0:
		apply_central_force(-v * sp * 0.4 * mass * 0.004)
		apply_torque(_flutter * clampf(sp / 150.0, 0.0, 1.0) * sin(_life * 7.0))
	if World.instance != null and World.instance.is_over_water(global_position.x, global_position.z) and global_position.y < 0.0:
		Fx.impact(get_parent(), Vector3(global_position.x, 0.0, global_position.z), Vector3.UP, true)
		queue_free()


func _on_body_entered(_b: Node) -> void:
	if _impacted:
		return
	_impacted = true
	if linear_velocity.length() > 15.0:
		Fx.explosion(get_parent(), global_position, 0.6, Vector3.ZERO)
	_life = minf(_life, 25.0)
