class_name WorldSky
extends RefCounted
## Procedural sky: analytic gradient with sun-side glow, Belt-of-Venus anti-twilight, sun/moon disk,
## a static cumulus layer and stars. Time of day only changes uniforms; nothing animates, so the sky's
## radiance map is only recomputed when the time of day changes.

const CODE := """
shader_type sky;
render_mode use_debanding;

uniform vec3 zenith : source_color = vec3(0.16, 0.33, 0.72);
uniform vec3 horizon : source_color = vec3(0.62, 0.74, 0.88);
uniform vec3 sun_glow : source_color = vec3(1.0, 0.9, 0.75);
uniform vec3 anti_glow : source_color = vec3(0.5, 0.45, 0.6);
uniform vec3 ground : source_color = vec3(0.32, 0.34, 0.36);
uniform float brightness = 1.0;
uniform float glow_strength = 0.4;
uniform float anti_strength = 0.0;
uniform float disk_energy = 40.0;
uniform float disk_size = 0.9995;
uniform float cloud_cover = 0.45;
uniform vec3 cloud_lit : source_color = vec3(1.0, 1.0, 1.0);
uniform vec3 cloud_shade : source_color = vec3(0.55, 0.6, 0.68);
uniform float stars = 0.0;

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash12(i), hash12(i + vec2(1, 0)), u.x), mix(hash12(i + vec2(0, 1)), hash12(i + vec2(1, 1)), u.x), u.y);
}

float fbm(vec2 p) {
	float s = 0.0;
	float a = 0.5;
	for (int i = 0; i < 5; i++) {
		s += a * vnoise(p);
		p = mat2(vec2(1.6, 1.2), vec2(-1.2, 1.6)) * p;
		a *= 0.5;
	}
	return s;
}

void sky() {
	vec3 d = normalize(EYEDIR);
	vec3 s = LIGHT0_ENABLED ? normalize(LIGHT0_DIRECTION) : vec3(0.0, 1.0, 0.0);
	float up = max(d.y, 0.0);
	float mu = dot(d, s);
	vec3 col = mix(horizon, zenith, pow(up, 0.45));
	// Horizon haze band.
	col = mix(col, horizon * 1.08, exp(-up * 18.0) * 0.6);
	// Forward scattering around the sun, stronger near the horizon.
	float g = pow(max(mu, 0.0), 6.0) * 0.6 + pow(max(mu, 0.0), 48.0) * 1.2;
	col += sun_glow * g * glow_strength * (0.4 + 0.6 * exp(-up * 4.0));
	// Anti-twilight arch opposite the sun.
	col = mix(col, anti_glow, anti_strength * pow(max(-mu, 0.0), 2.0) * exp(-up * 6.0));
	// Below the horizon: hazy ground.
	if (d.y < 0.0) {
		col = mix(horizon * 0.9, ground, 1.0 - exp(d.y * 12.0));
	}
	col *= brightness;
	// Stars.
	if (stars > 0.0 && d.y > 0.0) {
		vec2 sp = vec2(atan(d.x, d.z) * 180.0, acos(d.y) * 180.0);
		vec2 cell = floor(sp);
		float h = hash12(cell);
		vec2 off = vec2(hash12(cell + 7.1), hash12(cell + 3.3)) * 0.6 + 0.2;
		float dist = length(fract(sp) - off);
		float star = step(0.985, h) * smoothstep(0.12, 0.0, dist) * pow(hash12(cell + 1.7), 3.0);
		col += vec3(0.8, 0.85, 1.0) * star * stars * smoothstep(0.0, 0.15, d.y);
	}
	// Cloud layer: plane projection.
	if (d.y > 0.01 && cloud_cover > 0.0) {
		vec2 cp = d.xz / (d.y + 0.06) * 1.6 + vec2(3.7, 1.3);
		float n = fbm(cp);
		float dens = smoothstep(1.0 - cloud_cover, 1.0 - cloud_cover + 0.25, n);
		float lit = clamp(0.5 + (fbm(cp + s.xz * 0.08) - n) * 4.0, 0.0, 1.0);
		vec3 c = mix(cloud_shade, cloud_lit, lit) * brightness;
		c += sun_glow * pow(max(mu, 0.0), 8.0) * glow_strength * brightness * 0.8;
		float fade = smoothstep(0.01, 0.12, d.y);
		col = mix(col, c, dens * fade * 0.95);
	}
	// Sun / moon disk (not drawn into the radiance map's blurred mips via its small size).
	if (LIGHT0_ENABLED) {
		float disk = smoothstep(disk_size, disk_size + 0.00012, mu);
		col += LIGHT0_COLOR * disk * disk_energy * step(0.0, d.y + 0.02);
	}
	COLOR = col;
}
"""

var material: ShaderMaterial


func _init() -> void:
	var shader := Shader.new()
	shader.code = CODE
	material = ShaderMaterial.new()
	material.shader = shader


func apply(params: Dictionary) -> void:
	for k in params:
		material.set_shader_parameter(k, params[k])
