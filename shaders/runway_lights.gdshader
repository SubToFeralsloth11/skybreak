shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;

// Point-light sprites (MultiMesh of quads): runway/approach/taxi lights, PAPI, street lights, obstacle beacons.
// INSTANCE_CUSTOM: x = base size (m), y = PAPI transition angle in degrees (0 = plain light), z = blink phase (<0 = steady).
// Sprites keep a minimum on-screen size so they read as points from far away; haze dims them with distance.

uniform float intensity = 1.0;
uniform float min_pixel_angle = 0.0011;
uniform float haze_density = 0.00004;
uniform float far_falloff = 0.4;   // how fast far (enlarged) sprites dim: 0 = never, 1 = constant total energy

varying vec3 light_col;
varying float atten;

void vertex() {
	vec3 center = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	vec3 to_cam = CAMERA_POSITION_WORLD - center;
	float dist = length(to_cam);
	float size = max(INSTANCE_CUSTOM.x, dist * min_pixel_angle);
	vec3 right = INV_VIEW_MATRIX[0].xyz;
	vec3 up = INV_VIEW_MATRIX[1].xyz;
	vec3 world = center + (right * VERTEX.x + up * VERTEX.y) * size;
	POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(world, 1.0);
	vec3 c = COLOR.rgb;
	if (INSTANCE_CUSTOM.y > 0.0) {
		float elev = degrees(asin(clamp(to_cam.y / max(dist, 1.0), -1.0, 1.0)));
		c = elev > INSTANCE_CUSTOM.y ? vec3(1.0, 0.95, 0.9) : vec3(1.0, 0.1, 0.06);
	}
	float blink = 1.0;
	if (INSTANCE_CUSTOM.z >= 0.0) {
		blink = step(fract(TIME * 0.75 + INSTANCE_CUSTOM.z), 0.45);
	}
	// Far sprites are larger than the real lamp: scale energy back so total brightness stays plausible.
	float grow = INSTANCE_CUSTOM.x / size;
	atten = exp(-dist * haze_density) * blink * pow(grow, far_falloff);
	light_col = c;
}

void fragment() {
	float d = length(UV - 0.5) * 2.0;
	float core = exp(-d * d * 7.0);
	float halo = exp(-d * d * 2.0) * 0.25;
	ALBEDO = light_col * (core + halo) * intensity * atten;
	ALPHA = clamp(core + halo, 0.0, 1.0);
}
