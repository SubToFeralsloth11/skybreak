shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

// Heightmap-displaced terrain. Vertices snap to heightmap texels (texelFetch) so the mesh matches the
// collision height field exactly; shading uses filtered normals from the same map plus procedural detail.

uniform sampler2D heightmap : filter_linear, repeat_disable;
uniform sampler2D controlmap : filter_linear, repeat_disable;
uniform vec2 hm_origin;
uniform float hm_cell = 39.0625;
uniform int hm_size = 1025;
uniform float ctl_cell = 78.125;
uniform int ctl_size = 513;
uniform vec2 grid_origin = vec2(-720.0, 1000.0);
uniform float grid_pitch = 180.0;

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
	float a = hash12(i);
	float b = hash12(i + vec2(1.0, 0.0));
	float c = hash12(i + vec2(0.0, 1.0));
	float d = hash12(i + vec2(1.0, 1.0));
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

float fbm(vec2 p, int oct) {
	float s = 0.0;
	float a = 0.5;
	for (int i = 0; i < oct; i++) {
		s += a * vnoise(p);
		p = mat2(vec2(1.6, 1.2), vec2(-1.2, 1.6)) * p;
		a *= 0.5;
	}
	return s;
}

void vertex() {
	vec3 w = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	ivec2 t = clamp(ivec2(round((w.xz - hm_origin) / hm_cell)), ivec2(0), ivec2(hm_size - 1));
	float h = texelFetch(heightmap, t, 0).r - UV2.x;
	VERTEX.y = h;
	wpos = vec3(w.x, h, w.z);
}

float hm(vec2 xz) {
	vec2 uv = ((xz - hm_origin) / hm_cell + 0.5) / float(hm_size);
	return texture(heightmap, uv).r;
}

// Distance of p to the nearest street centreline of the shared city grid, and that street's half width.
vec2 street(float p, float origin) {
	float k = round((p - origin) / grid_pitch);
	float d = abs(p - (origin + k * grid_pitch));
	float avenue = 1.0 - mod(abs(k), 2.0);
	return vec2(d, avenue);
}

void fragment() {
	vec2 xz = wpos.xz;
	float dist = length(wpos - CAMERA_POSITION_WORLD);
	float e = hm_cell;
	float hl = hm(xz - vec2(e, 0.0));
	float hr = hm(xz + vec2(e, 0.0));
	float hd = hm(xz - vec2(0.0, e));
	float hu = hm(xz + vec2(0.0, e));
	vec3 n = normalize(vec3(hl - hr, 2.0 * e, hd - hu));
	float h = wpos.y;
	float slope = 1.0 - n.y;

	vec2 cuv = ((xz - hm_origin) / ctl_cell + 0.5) / float(ctl_size);
	vec4 ctl = texture(controlmap, cuv);

	float detail_fade = 1.0 - smoothstep(600.0, 3500.0, dist);
	float n_large = fbm(xz * 0.00035, 4);
	float n_mid = fbm(xz * 0.004, 4);
	float n_fine = fbm(xz * 0.06, 3);
	float n_micro = vnoise(xz * 0.9);

	// Base meadow: lush in hollows, drier on exposed ground.
	vec3 lush = vec3(0.038, 0.058, 0.022);
	vec3 dry = vec3(0.075, 0.072, 0.038);
	vec3 col = mix(lush, dry, smoothstep(0.35, 0.75, n_large + n_mid * 0.3 - 0.15));
	col *= 0.8 + 0.4 * n_mid;
	col *= mix(1.0, 0.85 + 0.3 * n_fine, detail_fade);

	// Farmland: rectangular fields on a slightly rotated grid, each with its own crop and row direction.
	if (ctl.a > 0.01) {
		vec2 fp = mat2(vec2(0.966, 0.259), vec2(-0.259, 0.966)) * xz;
		vec2 fsize = vec2(260.0, 170.0);
		vec2 fid = floor(fp / fsize);
		vec2 ff = fract(fp / fsize);
		float r = hash12(fid);
		vec3 crop;
		if (r < 0.25) crop = vec3(0.16, 0.13, 0.06);
		else if (r < 0.5) crop = vec3(0.045, 0.072, 0.024);
		else if (r < 0.68) crop = vec3(0.07, 0.052, 0.036);
		else if (r < 0.84) crop = vec3(0.10, 0.095, 0.05);
		else crop = vec3(0.065, 0.085, 0.035);
		crop *= 0.85 + 0.3 * hash12(fid + 7.0);
		float rows = 0.5 + 0.5 * sin((hash12(fid + 3.0) > 0.5 ? fp.x : fp.y) * 2.4);
		crop *= mix(1.0, 0.85 + 0.25 * rows, detail_fade * step(0.25, r));
		vec2 edge = min(ff, 1.0 - ff) * fsize;
		float hedge = 1.0 - smoothstep(1.5, 4.0, min(edge.x, edge.y));
		crop = mix(crop, vec3(0.03, 0.05, 0.02), hedge * 0.8);
		col = mix(col, crop, smoothstep(0.2, 0.6, ctl.a + (n_mid - 0.5) * 0.3));
	}

	// Forest floor / distant canopy.
	float canopy_n = fbm(xz * 0.012, 3) * 0.6 + fbm(xz * 0.09, 2) * 0.4;
	vec3 canopy = mix(vec3(0.016, 0.03, 0.014), vec3(0.035, 0.055, 0.022), canopy_n) * (0.8 + 0.4 * n_fine);
	col = mix(col, canopy, smoothstep(0.15, 0.6, ctl.r + (n_mid - 0.5) * 0.25));

	// Airport grounds: mown grass with stripes.
	vec3 mown = vec3(0.048, 0.066, 0.03) * (0.94 + 0.12 * step(0.5, fract(xz.x / 24.0))) * (0.85 + 0.3 * n_mid);
	col = mix(col, mown, ctl.b);

	// Towns: suburb lots with roofs and gardens on the street grid; paved core.
	if (ctl.g > 0.01) {
		vec2 sx = street(xz.x, grid_origin.x);
		vec2 sz = street(xz.y, grid_origin.y);
		vec3 asphalt = vec3(0.045, 0.045, 0.047) * (0.85 + 0.3 * n_fine);
		vec2 lot = floor(xz / 22.0);
		float lr = hash12(lot);
		vec3 garden = mix(vec3(0.05, 0.08, 0.03), vec3(0.09, 0.09, 0.05), hash12(lot + 3.0));
		vec3 roof = mix(vec3(0.16, 0.07, 0.05), vec3(0.11, 0.11, 0.12), step(0.5, hash12(lot + 9.0)));
		vec2 lf = fract(xz / 22.0);
		float house = step(0.3, lr) * step(0.2, lf.x) * step(lf.x, 0.75) * step(0.25, lf.y) * step(lf.y, 0.8);
		vec3 suburb = mix(garden, roof, house);
		float road_w = 7.0;
		float road = max(1.0 - smoothstep(road_w, road_w + 1.0, sx.x), 1.0 - smoothstep(road_w, road_w + 1.0, sz.x));
		suburb = mix(suburb, asphalt, road);
		float sub_w = smoothstep(0.1, 0.4, ctl.g);
		float core_w = smoothstep(0.6, 0.9, ctl.g);
		col = mix(col, suburb, sub_w * (1.0 - core_w));
		// Paved core: asphalt with lane markings on the street centrelines.
		vec3 core = asphalt;
		float lane = 0.0;
		float half_x = mix(20.0, 30.0, sx.y);
		float half_z = mix(20.0, 30.0, sz.y);
		if (sx.x < half_x && sz.x > half_z) lane = (1.0 - smoothstep(0.15, 0.3, sx.x)) * step(0.5, fract(xz.y / 12.0));
		if (sz.x < half_z && sx.x > half_x) lane = (1.0 - smoothstep(0.15, 0.3, sz.x)) * step(0.5, fract(xz.x / 12.0));
		// Pedestrian crossings at intersections.
		if (sx.x < half_x && sz.x > half_z && sz.x < half_z + 5.0) lane = step(0.5, fract(xz.x / 1.2));
		if (sz.x < half_z && sx.x > half_x && sx.x < half_x + 5.0) lane = step(0.5, fract(xz.y / 1.2));
		core = mix(core, vec3(0.5), lane * detail_fade * 0.8);
		col = mix(col, core, core_w);
	}

	// Beaches and wet sand along the waterline.
	vec3 sand = vec3(0.30, 0.26, 0.18) * (0.9 + 0.2 * n_fine);
	float beach = 1.0 - smoothstep(2.0, 3.2 + n_mid * 1.5, h);
	beach *= 1.0 - ctl.g * 0.9;
	col = mix(col, sand, beach);
	col = mix(col, vec3(0.16, 0.13, 0.085), 1.0 - smoothstep(-0.5, 0.8, h));

	// Alpine: thinning meadow, scree, rock on steep slopes, snow on the high flats.
	vec3 alpine = vec3(0.075, 0.07, 0.048) * (0.85 + 0.3 * n_mid);
	col = mix(col, alpine, smoothstep(1250.0, 1750.0, h + n_mid * 300.0) * (1.0 - ctl.r));
	vec3 rock = mix(vec3(0.05, 0.047, 0.043), vec3(0.13, 0.12, 0.105), n_mid);
	rock *= 0.8 + 0.4 * fbm(vec2(xz.x * 0.02, h * 0.15), 3);
	float rock_w = smoothstep(0.17, 0.32, slope + (n_fine - 0.5) * 0.12);
	rock_w = max(rock_w, smoothstep(1900.0, 2300.0, h) * smoothstep(0.08, 0.2, slope));
	col = mix(col, rock, rock_w);
	float snow_line = 1850.0 + (n_large - 0.5) * 500.0 + n_mid * 150.0;
	float snow = smoothstep(snow_line, snow_line + 120.0, h) * (1.0 - smoothstep(0.38, 0.55, slope + n_fine * 0.1));
	col = mix(col, vec3(0.78, 0.80, 0.85), snow);

	// Near-camera detail normal.
	float g = 0.6;
	float nx = fbm(xz * g + vec2(0.1, 0.0), 2) - fbm(xz * g - vec2(0.1, 0.0), 2);
	float nz = fbm(xz * g + vec2(0.0, 0.1), 2) - fbm(xz * g - vec2(0.0, 0.1), 2);
	float bump = detail_fade * (1.0 - ctl.g * 0.9) * mix(0.8, 2.0, rock_w);
	vec3 nd = normalize(n + vec3(-nx, 0.0, -nz) * bump);
	col *= mix(1.0, 0.9 + 0.2 * n_micro, detail_fade);

	ALBEDO = col;
	ROUGHNESS = mix(0.92, 0.55, snow);
	SPECULAR = 0.35;
	NORMAL = normalize((VIEW_MATRIX * vec4(nd, 0.0)).xyz);
}
