extends Node3D
## Root of an explosion: flies its burning debris chunks ballistically until they hit the ground.

var _age := 0.0


func _process(delta: float) -> void:
	_age += delta
	var world := World.instance
	for c in get_children():
		if not c.has_meta("vel"):
			continue
		var v: Vector3 = c.get_meta("vel")
		v += Vector3(0, -9.8, 0) * delta
		v *= 1.0 - 0.25 * delta
		var p: Vector3 = (c as Node3D).global_position + v * delta
		if world != null and p.y < world.surface_height_at(p.x, p.z):
			c.remove_meta("vel")
			continue
		(c as Node3D).global_position = p
		(c as Node3D).rotate_x(delta * 3.0)
		c.set_meta("vel", v)
		if _age > 4.0:
			for t in c.get_children():
				if t is GPUParticles3D:
					(t as GPUParticles3D).emitting = false
