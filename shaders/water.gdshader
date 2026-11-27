shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

// Ocean plane that follows the camera. Waves are world-space analytic slopes (no swimming), depth comes from
// the terrain heightmaps so shallows turn turquoise and the shoreline gets foam.

uniform sampler2D hm_inner : filter_linear, repeat_disable;
uniform sampler2D hm_outer : filter_linear, repeat_disable;
uniform vec3 inner_rect = vec3(-20000.0, -20000.0, 40000.0);   // origin x, origin z, size
uniform vec3 outer_rect = vec3(-80000.0, -80000.0, 160000.0);
uniform float inner_texels = 1025.0;
uniform float outer_texels = 257.0;
uniform vec3 deep_color : source_color = vec3(0.012, 0.045, 0.07);
uniform vec3 shallow_color : source_color = vec3(0.05, 0.22, 0.22);
uniform float sun_glint = 1.0;

varying vec3 wpos;

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

vec2 vnoise_grad(vec2 p) {
	float e = 0.05;
	return vec2(vnoise(p + vec2(e, 0.0)) - vnoise(p - vec2(e, 0.0)), vnoise(p + vec2(0.0, e)) - vnoise(p - vec2(0.0, e))) / (2.0 * e);
}

float terrain_h(vec2 xz) {
	vec2 ui = (xz - inner_rect.xy) / inner_rect.z;
	if (ui.x > 0.0 && ui.y > 0.0 && ui.x < 1.0 && ui.y < 1.0) {
		return texture(hm_inner, (ui * (inner_texels - 1.0) + 0.5) / inner_texels).r;
	}
	vec2 uo = clamp((xz - outer_rect.xy) / outer_rect.z, 0.0, 1.0);
	return texture(hm_outer, (uo * (outer_texels - 1.0) + 0.5) / outer_texels).r;
}

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 xz = wpos.xz;
	float dist = length(wpos - CAMERA_POSITION_WORLD);
	float t = TIME;
	// Directional swell + wind chop (slopes of sine waves), fading with distance to avoid aliasing.
	vec2 slope = vec2(0.0);
	vec2 dirs[6] = vec2[](vec2(0.8, 0.6), vec2(0.6, 0.8), vec2(0.95, -0.3), vec2(0.3, 0.95), vec2(-0.5, 0.86), vec2(0.99, 0.12));
	float lens[6] = float[](140.0, 75.0, 38.0, 21.0, 11.0, 6.0);
	float amps[6] = float[](0.9, 0.45, 0.22, 0.12, 0.06, 0.035);
	for (int i = 0; i < 6; i++) {
		float k = 6.2832 / lens[i];
		float w = sqrt(9.81 * k);
		float fade = 1.0 - smoothstep(lens[i] * 25.0, lens[i] * 90.0, dist);
		float ph = dot(dirs[i], xz) * k - w * t;
		slope += dirs[i] * (amps[i] * k * cos(ph)) * fade;
	}
	float ripple_fade = 1.0 - smoothstep(80.0, 900.0, dist);
	// Noise gradients are in noise space: scale by frequency * amplitude (m) to get world slopes.
	slope += vnoise_grad(xz * 0.35 + vec2(t * 0.25, t * 0.1)) * (0.35 * 0.12) * ripple_fade;
	slope += vnoise_grad(xz * 1.3 - vec2(t * 0.4, -t * 0.3)) * (1.3 * 0.025) * ripple_fade;
	slope += vnoise_grad(xz * 0.02 + vec2(t * 0.01, 0.0)) * (0.02 * 1.2) * (1.0 - smoothstep(4000.0, 15000.0, dist));
	vec3 n = normalize(vec3(-slope.x, 1.0, -slope.y));

	float depth = max(-terrain_h(xz), 0.0);
	vec3 col = mix(shallow_color, deep_color, smoothstep(0.5, 22.0, depth));
	// Foam: surf line plus whitecaps on the steepest chop.
	float surf = (1.0 - smoothstep(0.2, 2.2, depth)) * smoothstep(0.35, 0.7, vnoise(xz * 0.25 + vec2(t * 0.3, 0.0)) + 0.3 * sin(depth * 4.0 - t * 1.6));
	float caps = smoothstep(0.8, 0.97, vnoise(xz * 0.06 + vec2(t * 0.05, t * 0.03))) * smoothstep(0.65, 0.9, vnoise(xz * 0.7 + t * 0.2)) * 0.15 * ripple_fade;
	float foam = clamp(surf + caps, 0.0, 1.0);
	col = mix(col, vec3(0.75, 0.78, 0.8), foam);

	ALBEDO = col;
	ROUGHNESS = mix(mix(0.03, 0.09, smoothstep(300.0, 12000.0, dist)), 0.7, foam);
	SPECULAR = 0.55 * sun_glint;
	METALLIC = 0.0;
	NORMAL = normalize((VIEW_MATRIX * vec4(n, 0.0)).xyz);
}
