shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

// Low-poly trees (MultiMesh). UV.x: 0 trunk, 1 foliage. INSTANCE_CUSTOM.rgb = foliage tint, .a = sway phase.

uniform float wind = 1.0;

varying vec3 tint;
varying float foliage;
varying vec3 lpos;

float hash13(vec3 p3) {
	p3 = fract(p3 * 0.1031);
	p3 += dot(p3, p3.zyx + 31.32);
	return fract((p3.x + p3.y) * p3.z);
}

void vertex() {
	foliage = UV.x;
	tint = INSTANCE_CUSTOM.rgb;
	lpos = VERTEX;
	float sway = sin(TIME * 1.1 + INSTANCE_CUSTOM.a * 6.2832) * 0.025 * wind * max(VERTEX.y, 0.0) * foliage;
	VERTEX.x += sway;
	VERTEX.z += sway * 0.6;
}

void fragment() {
	vec3 trunk = vec3(0.09, 0.06, 0.04);
	float leaf = hash13(floor(lpos * 2.2));
	vec3 leaves = tint * (0.75 + 0.45 * leaf);
	// Self-shadowed interior: darker towards the bottom and inside of the crown.
	leaves *= mix(0.65, 1.1, clamp(lpos.y / 14.0, 0.0, 1.0));
	ALBEDO = mix(trunk, leaves, foliage);
	ROUGHNESS = 0.9;
	SPECULAR = 0.25;
	BACKLIGHT = vec3(0.12, 0.16, 0.06) * foliage;
}
