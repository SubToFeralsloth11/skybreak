extends SceneTree

func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var layout := WorldLayout.new()
	var t := WorldTerrain.new(layout)
	root.add_child(t)
	await t.generate(func(_f: float) -> void: pass)
	t.build_nodes()
	await physics_frame
	await physics_frame
	var space := t.get_world_3d().direct_space_state
	var n := WorldLayout.SAMPLES
	var e_a := 0.0
	var e_b := 0.0
	var e_bl := 0.0
	for k in 300:
		var x := randf_range(-18000.0, 18000.0)
		var z := randf_range(-18000.0, -6000.0)
		var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(Vector3(x, 4000, z), Vector3(x, -200, z)))
		if hit.is_empty():
			continue
		var fx := (x + WorldLayout.HALF) / WorldLayout.CELL
		var fz := (z + WorldLayout.HALF) / WorldLayout.CELL
		var i := int(fx)
		var j := int(fz)
		var tx := fx - i
		var tz := fz - j
		var h00 := t.heights[j * n + i]
		var h10 := t.heights[j * n + i + 1]
		var h01 := t.heights[(j + 1) * n + i]
		var h11 := t.heights[(j + 1) * n + i + 1]
		var a := t.height_at(x, z)
		# other diagonal (i+1, j) - (i, j+1)
		var b: float
		if tx + tz <= 1.0:
			b = h00 + tx * (h10 - h00) + tz * (h01 - h00)
		else:
			b = h11 + (1.0 - tx) * (h01 - h11) + (1.0 - tz) * (h10 - h11)
		var bl := lerpf(lerpf(h00, h10, tx), lerpf(h01, h11, tx), tz)
		var y: float = hit.position.y
		e_a = maxf(e_a, absf(y - a))
		e_b = maxf(e_b, absf(y - b))
		e_bl = maxf(e_bl, absf(y - bl))
	print("diag A err %.2f  diag B err %.2f  bilinear err %.2f" % [e_a, e_b, e_bl])
	quit()
