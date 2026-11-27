shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled;
// Afterburner plume: blue-white core with shock diamonds fading to orange. Mesh: cylinder along local Y,
// nozzle at y = +half_length.

uniform float intensity = 1.0;   // 0 = off, ~0.25 military power glow, 1 = full reheat
uniform float half_length = 3.0;
uniform float time_offset = 0.0;

varying float along;

void vertex() {
	along = clamp((half_length - VERTEX.y) / (2.0 * half_length), 0.0, 1.0); // 0 at nozzle, 1 at tail
}

void fragment() {
	float edge = pow(clamp(abs(dot(NORMAL, VIEW)), 0.0, 1.0), 1.6);
	float diamonds = 0.55 + 0.45 * sin(along * 38.0 - TIME * 4.0 + time_offset) * (1.0 - along);
	float flicker = 0.85 + 0.15 * sin(TIME * 63.0 + time_offset * 7.0) * sin(TIME * 41.0);
	vec3 core = vec3(0.55, 0.7, 1.0);
	vec3 hot = vec3(1.0, 0.55, 0.2);
	vec3 col = mix(core, hot, smoothstep(0.15, 0.7, along));
	float fade = (1.0 - smoothstep(0.2, 1.0, along)) * edge;
	float a = fade * mix(diamonds, 1.0, 0.3) * flicker * intensity;
	ALBEDO = col * a * 3.0;
	ALPHA = clamp(a, 0.0, 1.0);
}
