class_name Sfx
extends RefCounted
## Procedurally synthesised sounds (no audio assets). Call Sfx.setup(host) once.
## World sounds go to the "Ext" bus, which is low-passed while the camera is in the cockpit.

const RATE := 22050
static var streams := {}
static var host: Node
static var _ext_lowpass: AudioEffectLowPassFilter


static func setup(p_host: Node) -> void:
	host = p_host
	if AudioServer.get_bus_index("Ext") == -1:
		AudioServer.add_bus()
		var idx := AudioServer.bus_count - 1
		AudioServer.set_bus_name(idx, "Ext")
		AudioServer.set_bus_send(idx, "Master")
		_ext_lowpass = AudioEffectLowPassFilter.new()
		_ext_lowpass.cutoff_hz = 20000.0
		AudioServer.add_bus_effect(idx, _ext_lowpass)
		var comp := AudioEffectCompressor.new()
		comp.threshold = -10.0
		comp.ratio = 6.0
		AudioServer.add_bus_effect(0, comp)
		var lim := AudioEffectHardLimiter.new()
		AudioServer.add_bus_effect(0, lim)
	if streams.is_empty():
		_generate()


static func set_cockpit(inside: bool) -> void:
	if _ext_lowpass != null:
		_ext_lowpass.cutoff_hz = 1700.0 if inside else 20000.0


# ------------------------------------------------------------------ playback

static func play(name: String, volume_db := 0.0, pitch := 1.0) -> AudioStreamPlayer:
	if host == null or not streams.has(name):
		return null
	var p := AudioStreamPlayer.new()
	p.stream = streams[name]
	p.volume_db = volume_db
	p.pitch_scale = pitch
	host.add_child(p)
	p.play()
	p.finished.connect(p.queue_free)
	return p


static func play_at(name: String, pos: Vector3, scale := 1.0) -> void:
	if host == null or not streams.has(name) or not host.is_inside_tree():
		return
	# Sound travels at ~343 m/s: distant explosions are heard after you see them.
	var cam := host.get_viewport().get_camera_3d()
	var delay := 0.0
	if cam != null:
		delay = minf(cam.global_position.distance_to(pos) / 343.0, 8.0)
	var p := AudioStreamPlayer3D.new()
	p.stream = streams[name]
	p.bus = "Ext"
	p.unit_size = 40.0 * scale
	p.max_db = 6.0
	p.volume_db = 4.0 + 4.0 * log(scale) / log(2.0)
	p.pitch_scale = clampf(1.15 - 0.15 * scale, 0.6, 1.3) * randf_range(0.92, 1.08)
	p.max_distance = 9000.0
	p.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	host.add_child(p)
	p.global_position = pos
	p.finished.connect(p.queue_free)
	if delay > 0.05:
		host.get_tree().create_timer(delay, false).timeout.connect(func():
			if is_instance_valid(p):
				p.play())
	else:
		p.play()


static func loop_player(name: String, parent: Node3D, unit_size := 30.0) -> AudioStreamPlayer3D:
	var p := AudioStreamPlayer3D.new()
	p.stream = streams.get(name)
	p.bus = "Ext"
	p.unit_size = unit_size
	p.max_distance = 12000.0
	p.doppler_tracking = AudioStreamPlayer3D.DOPPLER_TRACKING_PHYSICS_STEP
	p.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	p.volume_db = -80.0
	parent.add_child(p)
	p.play()
	return p


static func loop_2d(name: String, volume_db := 0.0) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.stream = streams.get(name)
	p.volume_db = volume_db
	host.add_child(p)
	return p


# ------------------------------------------------------------------ synthesis

static func _wav(samples: PackedFloat32Array, loop := false) -> AudioStreamWAV:
	var bytes := PackedByteArray()
	bytes.resize(samples.size() * 2)
	for i in samples.size():
		bytes.encode_s16(i * 2, int(clampf(samples[i], -1.0, 1.0) * 32000.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = RATE
	w.stereo = false
	w.data = bytes
	if loop:
		w.loop_mode = AudioStreamWAV.LOOP_FORWARD
		w.loop_begin = 0
		w.loop_end = samples.size()
	return w


## Make a noise buffer loop seamlessly by crossfading its tail into its head.
static func _seamless(s: PackedFloat32Array, fade: int) -> PackedFloat32Array:
	var n := s.size() - fade
	var out := PackedFloat32Array()
	out.resize(n)
	for i in n:
		out[i] = s[i]
	for i in fade:
		var t := float(i) / fade
		out[i] = s[i] * t + s[n + i] * (1.0 - t)
	return out


static func _normalize(s: PackedFloat32Array, peak := 0.9) -> PackedFloat32Array:
	var m := 0.0001
	for v in s:
		m = maxf(m, absf(v))
	var k := peak / m
	for i in s.size():
		s[i] *= k
	return s


static func _generate() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	# Jet core rumble: brown noise, low-passed twice.
	var n := RATE * 3
	var s := PackedFloat32Array()
	s.resize(n + 4000)
	var b := 0.0
	var lp := 0.0
	for i in s.size():
		b = (b + rng.randf_range(-1, 1) * 0.08) * 0.995
		lp += (b - lp) * 0.12
		s[i] = lp
	streams["jet_rumble"] = _wav(_normalize(_seamless(s, 4000), 0.8), true)
	# Turbine whine: integer cycles per 1 s loop.
	s = PackedFloat32Array()
	s.resize(RATE)
	for i in RATE:
		var t := float(i) / RATE
		s[i] = 0.5 * sin(TAU * 1100.0 * t) + 0.25 * sin(TAU * 2200.0 * t) + 0.12 * sin(TAU * 3300.0 * t + 0.4) + 0.15 * sin(TAU * 170.0 * t) + rng.randf_range(-0.05, 0.05)
	streams["jet_whine"] = _wav(_normalize(s, 0.6), true)
	# Afterburner / exhaust roar: pinkish noise with random crackle.
	s = PackedFloat32Array()
	s.resize(n + 4000)
	var p1 := 0.0
	var p2 := 0.0
	for i in s.size():
		var w := rng.randf_range(-1, 1)
		p1 = 0.97 * p1 + w * 0.15
		p2 += (w - p2) * 0.35
		var crackle := (rng.randf_range(-1, 1) * 2.0) if rng.randf() < 0.004 else 0.0
		s[i] = p1 * 0.9 + p2 * 0.35 + crackle * 0.4
	streams["roar"] = _wav(_normalize(_seamless(s, 4000), 0.8), true)
	# Wind: band-limited noise.
	s = PackedFloat32Array()
	s.resize(n + 4000)
	var h := 0.0
	var l2 := 0.0
	for i in s.size():
		var w2 := rng.randf_range(-1, 1)
		l2 += (w2 - l2) * 0.08
		h = l2 - h * 0.2
		s[i] = h
	streams["wind"] = _wav(_normalize(_seamless(s, 4000), 0.7), true)
	# M61 cannon: 100 rounds/s buzz, 1 s loop.
	s = PackedFloat32Array()
	s.resize(RATE)
	var per := RATE / 100
	for i in RATE:
		var k := i % per
		var env := exp(-float(k) / (RATE * 0.0025))
		var thump := sin(TAU * 100.0 * float(i) / RATE) * 0.5
		s[i] = rng.randf_range(-1, 1) * env * 0.9 + thump * 0.6 + sin(TAU * 300.0 * float(i) / RATE) * 0.2
	streams["gun"] = _wav(_normalize(s, 0.85), true)
	# Explosion: crack + long boom.
	var en := int(RATE * 4.0)
	s = PackedFloat32Array()
	s.resize(en)
	b = 0.0
	lp = 0.0
	for i in en:
		var t2 := float(i) / RATE
		b = (b + rng.randf_range(-1, 1) * 0.2) * 0.996
		lp += (b - lp) * (0.25 * exp(-t2 * 0.8) + 0.03)
		var boom := sin(TAU * (55.0 - 25.0 * minf(t2, 1.0)) * t2) * exp(-t2 * 2.2)
		var crack := rng.randf_range(-1, 1) * exp(-t2 * 40.0)
		s[i] = (lp * 1.4 + boom * 0.8 + crack * 0.9) * exp(-t2 * 0.9) * minf(1.0, t2 * 400.0)
	streams["explosion"] = _wav(_normalize(s, 0.95))
	# Missile launch whoosh.
	en = int(RATE * 2.6)
	s = PackedFloat32Array()
	s.resize(en)
	lp = 0.0
	for i in en:
		var t3 := float(i) / RATE
		var w3 := rng.randf_range(-1, 1)
		lp += (w3 - lp) * 0.3
		s[i] = lp * minf(1.0, t3 * 12.0) * exp(-t3 * 1.1)
	streams["missile"] = _wav(_normalize(s, 0.9))
	# Bullet hit on metal.
	en = int(RATE * 0.25)
	s = PackedFloat32Array()
	s.resize(en)
	for i in en:
		var t4 := float(i) / RATE
		s[i] = (rng.randf_range(-1, 1) * exp(-t4 * 60.0) + 0.5 * sin(TAU * 870.0 * t4) * exp(-t4 * 25.0) + 0.3 * sin(TAU * 1310.0 * t4) * exp(-t4 * 30.0))
	streams["hit"] = _wav(_normalize(s, 0.8))
	# Metal tearing (wing/engine separating).
	en = int(RATE * 1.4)
	s = PackedFloat32Array()
	s.resize(en)
	lp = 0.0
	for i in en:
		var t5 := float(i) / RATE
		var w5 := rng.randf_range(-1, 1)
		lp += (w5 - lp) * 0.5
		var groan := sin(TAU * (260.0 - 120.0 * t5) * t5 + sin(t5 * 90.0) * 2.0)
		s[i] = (lp * 0.7 * (0.6 + 0.4 * sin(t5 * 70.0)) + groan * 0.5) * exp(-t5 * 2.0)
	streams["tear"] = _wav(_normalize(s, 0.9))
	# Sidewinder seeker growl and lock tone (1 s loops, integer cycles).
	s = PackedFloat32Array()
	s.resize(RATE)
	for i in RATE:
		var t6 := float(i) / RATE
		s[i] = sin(TAU * 400.0 * t6) * (0.6 + 0.4 * sin(TAU * 13.0 * t6)) + rng.randf_range(-0.1, 0.1)
	streams["growl"] = _wav(_normalize(s, 0.5), true)
	s = PackedFloat32Array()
	s.resize(RATE)
	for i in RATE:
		var t7 := float(i) / RATE
		s[i] = sin(TAU * 1600.0 * t7) * 0.8 + sin(TAU * 3200.0 * t7) * 0.15
	streams["lock"] = _wav(_normalize(s, 0.45), true)
	# Missile warning: fast alternating beeps, 0.5 s loop.
	en = RATE / 2
	s = PackedFloat32Array()
	s.resize(en)
	for i in en:
		var t8 := float(i) / RATE
		var f := 1000.0 if t8 < 0.25 else 1400.0
		var gate := 1.0 if fmod(t8, 0.25) < 0.17 else 0.0
		s[i] = signf(sin(TAU * f * t8)) * 0.35 * gate
	streams["warning"] = _wav(s, true)
	# Stall horn / generic caution.
	en = int(RATE * 0.6)
	s = PackedFloat32Array()
	s.resize(en)
	for i in en:
		var t9 := float(i) / RATE
		s[i] = (sin(TAU * 500.0 * t9) + 0.4 * sin(TAU * 1000.0 * t9)) * (1.0 if t9 < 0.4 else 0.0) * 0.4
	streams["caution"] = _wav(s, true)
	# Flare pop.
	en = int(RATE * 0.35)
	s = PackedFloat32Array()
	s.resize(en)
	for i in en:
		var t10 := float(i) / RATE
		s[i] = rng.randf_range(-1, 1) * exp(-t10 * 18.0) + sin(TAU * 140.0 * t10) * exp(-t10 * 25.0)
	streams["flare"] = _wav(_normalize(s, 0.7))
	# Ring / trick chime.
	en = int(RATE * 0.7)
	s = PackedFloat32Array()
	s.resize(en)
	for i in en:
		var t11 := float(i) / RATE
		s[i] = (sin(TAU * 880.0 * t11) + 0.6 * sin(TAU * 1320.0 * t11) * minf(1.0, t11 * 8.0) + 0.3 * sin(TAU * 1760.0 * t11)) * exp(-t11 * 5.0)
	streams["chime"] = _wav(_normalize(s, 0.6))
	# Tyre chirp.
	en = int(RATE * 0.3)
	s = PackedFloat32Array()
	s.resize(en)
	lp = 0.0
	for i in en:
		var t12 := float(i) / RATE
		var w12 := rng.randf_range(-1, 1)
		lp += (w12 - lp) * 0.6
		s[i] = (w12 - lp) * exp(-t12 * 12.0) + sin(TAU * 1900.0 * t12) * 0.25 * exp(-t12 * 14.0)
	streams["chirp"] = _wav(_normalize(s, 0.7))
	# Gear / flap motor whir + clunk.
	en = int(RATE * 1.6)
	s = PackedFloat32Array()
	s.resize(en)
	for i in en:
		var t13 := float(i) / RATE
		var whir := sin(TAU * 190.0 * t13 + sin(TAU * 7.0 * t13)) * 0.3 * (1.0 if t13 < 1.3 else 0.0)
		var clunk := rng.randf_range(-1, 1) * exp(-maxf(t13 - 1.3, 0.0) * 30.0) * (1.0 if t13 > 1.3 else 0.0)
		s[i] = whir + clunk
	streams["gear"] = _wav(_normalize(s, 0.6))
	# UI click.
	en = int(RATE * 0.05)
	s = PackedFloat32Array()
	s.resize(en)
	for i in en:
		s[i] = sin(TAU * 2000.0 * float(i) / RATE) * exp(-float(i) / RATE * 90.0)
	streams["click"] = _wav(_normalize(s, 0.5))
