shader_type spatial;
// Aircraft skin: base paint, optional two-tone camouflage or airline livery, panel lines,
// passenger windows, grime, and scorch from damage. Works in body (model) space so detached
// parts keep their pattern.

uniform vec3 base_color : source_color = vec3(0.56, 0.58, 0.6);
uniform vec3 second_color : source_color = vec3(0.42, 0.45, 0.48);
uniform vec3 accent_color : source_color = vec3(0.08, 0.2, 0.55);
uniform int scheme = 0; // 0 plain, 1 fighter two-tone camo, 2 airline livery, 3 aggressor splinter
uniform float metallic_amount = 0.35;
uniform float roughness_amount = 0.5;
uniform float panel_scale = 1.4;
uniform float scorch = 0.0; // 0..1 burn/soot amount
uniform vec4 window_band = vec4(0.65, 0.34, -13.0, 13.5); // y centre, half height, z min, z max
uniform float window_pitch = 0.53;
uniform float belly_y = -0.55;
uniform float tail_z = 12.0;

varying vec3 body_pos;
varying vec3 body_normal;

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float hash3(vec3 p) { return fract(sin(dot(p, vec3(127.1, 311.7, 74.7))) * 43758.5453); }
float noise(vec2 p) {
	vec2 i = floor(p), f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1, 0)), f.x), mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), f.x), f.y);
}
float fbm(vec2 p) {
	float v = 0.0, a = 0.5;
	for (int i = 0; i < 4; i++) { v += a * noise(p); p *= 2.03; a *= 0.5; }
	return v;
}

void vertex() {
	body_pos = VERTEX;
	body_normal = NORMAL;
}

void fragment() {
	vec3 p = body_pos;
	vec3 col = base_color;
	float rough = roughness_amount;
	float metal = metallic_amount;

	if (scheme == 1) {
		// Two-tone counter-shading: darker on top surfaces in soft blobs, light underside.
		float n = fbm(p.xz * 0.16 + vec2(3.1, 1.7));
		float top = smoothstep(-0.2, 0.4, body_normal.y);
		col = mix(base_color, second_color, step(0.52, n) * top);
	} else if (scheme == 3) {
		float n = fbm(floor(p.xz * 0.5) * 0.37 + p.y * 0.05);
		col = n > 0.62 ? accent_color : (n > 0.45 ? second_color : base_color);
	} else if (scheme == 2) {
		// White top, grey belly, blue cheat line and tail.
		float belly = smoothstep(belly_y + 0.05, belly_y - 0.05, p.y) * step(abs(p.x), 2.2);
		col = mix(base_color, second_color, belly);
		float stripe = step(abs(p.y - (window_band.x - window_band.y - 0.28)), 0.09) * step(window_band.z, p.z) * step(p.z, window_band.w + 3.0) * step(abs(p.x), 2.2);
		col = mix(col, accent_color, stripe);
		float tail = step(tail_z, p.z) * step(1.9, p.y) * step(abs(p.x), 0.5);
		col = mix(col, accent_color, tail);
		// Passenger windows on the fuselage sides.
		float side = step(0.25, abs(body_normal.x));
		float wz = fract((p.z - window_band.z) / window_pitch);
		float in_band = step(abs(p.y - window_band.x), window_band.y * 0.5) * step(window_band.z, p.z) * step(p.z, window_band.w);
		float win = in_band * side * step(0.22, wz) * step(wz, 0.72);
		// Door gaps instead of windows near the ends.
		win *= 1.0 - step(abs(p.z - (window_band.z + 1.2)), 0.6) - step(abs(p.z - (window_band.w - 0.8)), 0.6);
		col = mix(col, vec3(0.03, 0.04, 0.06), clamp(win, 0.0, 1.0));
		rough = mix(rough, 0.08, clamp(win, 0.0, 1.0));
	}

	// Panel lines: thin dark grid in body space, softened.
	vec3 g = abs(fract(p * panel_scale) - 0.5);
	float line_z = smoothstep(0.485, 0.497, g.z);
	float line_x = smoothstep(0.488, 0.498, g.x) * step(0.6, abs(body_normal.y));
	float panel = max(line_z, line_x) * 0.35;
	col *= 1.0 - panel;
	// Rivet-scale variation and grime.
	float grime = fbm(p.zx * vec2(0.6, 2.0) + p.y);
	col *= 0.9 + 0.12 * grime;
	rough += (grime - 0.5) * 0.15;

	// Scorch from damage, blotchy.
	float burn = smoothstep(1.0 - scorch, 1.05 - scorch * 0.6, fbm(p.xz * 0.9 + p.y));
	col = mix(col, vec3(0.025, 0.022, 0.02), burn * scorch);
	rough = mix(rough, 0.95, burn * scorch);

	ALBEDO = col;
	METALLIC = metal;
	ROUGHNESS = clamp(rough, 0.05, 1.0);
	SPECULAR = 0.5;
}
