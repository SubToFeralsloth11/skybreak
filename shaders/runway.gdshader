shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

// Paved surfaces. UV = (metres across the centreline, metres along from the start).
// mode 0: runway with ICAO-style markings (piano keys, designators, centreline, aiming point, touchdown zone,
// edge stripes, shoulders). mode 1: taxiway. mode 2: concrete apron.

uniform int mode = 0;
uniform float rwy_length = 3000.0;
uniform float width = 45.0;
uniform int number_a = 9;
uniform int number_b = 27;

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

float box(vec2 p, vec2 a, vec2 b) {
	return step(a.x, p.x) * step(p.x, b.x) * step(a.y, p.y) * step(p.y, b.y);
}

// Seven-segment digit in a w x h cell; p relative to the cell's near-left corner.
float digit(vec2 p, int d, vec2 size, float s) {
	int bits = 0;
	if (d == 0) bits = 63;
	else if (d == 1) bits = 6;
	else if (d == 2) bits = 91;
	else if (d == 3) bits = 79;
	else if (d == 4) bits = 102;
	else if (d == 5) bits = 109;
	else if (d == 6) bits = 125;
	else if (d == 7) bits = 7;
	else if (d == 8) bits = 127;
	else bits = 111;
	float w = size.x;
	float h = size.y;
	float m = 0.0;
	if ((bits & 1) != 0) m += box(p, vec2(0.0, h - s), vec2(w, h));            // a: far (top)
	if ((bits & 2) != 0) m += box(p, vec2(w - s, h * 0.5), vec2(w, h));        // b: top right
	if ((bits & 4) != 0) m += box(p, vec2(w - s, 0.0), vec2(w, h * 0.5));      // c: bottom right
	if ((bits & 8) != 0) m += box(p, vec2(0.0, 0.0), vec2(w, s));              // d: near (bottom)
	if ((bits & 16) != 0) m += box(p, vec2(0.0, 0.0), vec2(s, h * 0.5));       // e
	if ((bits & 32) != 0) m += box(p, vec2(0.0, h * 0.5), vec2(s, h));         // f
	if ((bits & 64) != 0) m += box(p, vec2(0.0, h * 0.5 - s * 0.5), vec2(w, h * 0.5 + s * 0.5)); // g
	return min(m, 1.0);
}

float designator(vec2 p, int n) {
	vec2 size = vec2(5.0, 16.0);
	float s = 1.3;
	int tens = n / 10;
	int ones = n - tens * 10;
	float gap = 2.0;
	float m = 0.0;
	if (tens > 0) {
		m += digit(p - vec2(-size.x - gap * 0.5, 0.0), tens, size, s);
		m += digit(p - vec2(gap * 0.5, 0.0), ones, size, s);
	} else {
		m += digit(p - vec2(-size.x * 0.5, 0.0), ones, size, s);
	}
	return min(m, 1.0);
}

// Markings for one runway end; p = (across, along from this threshold).
float end_marks(vec2 p, int number) {
	float ax = abs(p.x);
	float hw = width * 0.5;
	float m = 0.0;
	// Threshold piano keys.
	if (p.y > 6.0 && p.y < 36.0 && ax > 2.0 && ax < hw - 3.0) m += step(fract((ax - 2.0) / 3.6), 0.5);
	// Designator.
	m += designator(p - vec2(0.0, 46.0), number);
	// Aiming point.
	m += box(vec2(ax, p.y), vec2(9.0, 400.0), vec2(19.0, 460.0));
	// Touchdown zone bars.
	float tdz_at[5] = float[](150.0, 300.0, 550.0, 700.0, 850.0);
	int tdz_n[5] = int[](3, 3, 2, 2, 1);
	for (int i = 0; i < 5; i++) {
		if (p.y > tdz_at[i] && p.y < tdz_at[i] + 22.5) {
			for (int k = 0; k < tdz_n[i]; k++) {
				float x0 = 9.0 + float(k) * 3.3;
				m += box(vec2(ax, p.y), vec2(x0, tdz_at[i]), vec2(x0 + 1.8, tdz_at[i] + 22.5));
			}
		}
	}
	return m;
}

void fragment() {
	vec2 p = UV;
	float ax = abs(p.x);
	vec3 wp = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float n1 = vnoise(wp.xz * 0.15);
	float n2 = vnoise(wp.xz * 2.5);
	float n3 = vnoise(wp.xz * 0.02);
	vec3 asphalt = vec3(0.055, 0.055, 0.058) * (0.8 + 0.25 * n1 + 0.15 * n2) * (0.9 + 0.2 * n3);
	vec3 col = asphalt;
	vec3 paint = vec3(0.0);
	float paint_m = 0.0;
	float rough = 0.88;
	// Fade sub-pixel markings into the average to avoid shimmering.
	float px = max(fwidth(p.x), fwidth(p.y));

	if (mode == 0) {
		float hw = width * 0.5;
		if (ax > hw) {
			col = vec3(0.085, 0.083, 0.08) * (0.85 + 0.2 * n1);   // paved shoulders
		}
		float m = 0.0;
		m += end_marks(p, number_a);
		m += end_marks(vec2(-p.x, rwy_length - p.y), number_b);
		// Centreline dashes.
		if (p.y > 70.0 && p.y < rwy_length - 70.0 && ax < 0.45) m += step(fract((p.y - 70.0) / 50.0), 0.6);
		// Edge stripes.
		if (ax > hw - 1.0 && ax < hw) m += 1.0;
		m = min(m, 1.0);
		// Rubber deposits in both touchdown zones.
		float tz = max(1.0 - smoothstep(250.0, 900.0, abs(p.y - 500.0)), 1.0 - smoothstep(250.0, 900.0, abs(p.y - (rwy_length - 500.0))));
		float rubber = tz * (1.0 - smoothstep(4.0, 12.0, ax)) * (0.5 + 0.5 * vnoise(vec2(p.x * 1.5, p.y * 0.05)));
		col *= 1.0 - rubber * 0.55;
		paint = vec3(0.62, 0.62, 0.6) * (0.85 + 0.15 * n2);
		paint_m = m * (1.0 - rubber * 0.6) * (0.75 + 0.25 * step(0.3, n2));
	} else if (mode == 1) {
		float hw = width * 0.5;
		float m = 1.0 - smoothstep(0.15, 0.2 + px, ax);
		m += box(vec2(ax, 0.0), vec2(hw - 0.9, -1.0), vec2(hw - 0.75, 1.0));
		m += box(vec2(ax, 0.0), vec2(hw - 0.55, -1.0), vec2(hw - 0.4, 1.0));
		paint = vec3(0.55, 0.40, 0.05);
		paint_m = min(m, 1.0) * clamp(1.0 - px * 2.0, 0.0, 1.0);
	} else {
		vec2 slab = floor(wp.xz / 7.5);
		vec2 sf = fract(wp.xz / 7.5);
		float joint = step(0.985, max(sf.x, sf.y));
		col = vec3(0.24, 0.235, 0.22) * (0.85 + 0.15 * hash12(slab)) * (0.85 + 0.2 * n1) * (1.0 - joint * 0.4 * clamp(1.0 - px * 4.0, 0.0, 1.0));
		col *= 1.0 - 0.25 * smoothstep(0.55, 0.9, vnoise(wp.xz * 0.08));   // oil stains
		float lead = 1.0 - smoothstep(0.15, 0.2 + px, abs(fract(p.y / 70.0 + 0.5) - 0.5) * 70.0);
		paint = vec3(0.55, 0.40, 0.05);
		paint_m = lead * clamp(1.0 - px * 2.0, 0.0, 1.0);
		rough = 0.8;
	}
	col = mix(col, paint, paint_m);
	ALBEDO = col;
	ROUGHNESS = rough - paint_m * 0.15;
	SPECULAR = 0.4;
}
