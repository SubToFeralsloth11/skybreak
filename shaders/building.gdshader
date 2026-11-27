shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

// Procedural facades for merged building meshes.
// UV  = (metres along the facade, metres above the building's ground)
// UV2 = (style, per-building seed)   COLOR = facade tint
// Styles: 0 glass curtain wall, 1 concrete ribbon windows, 2 brick punched windows, 3 dark glass with fins,
// 4 stone grid, 5 plain concrete, 6 corrugated metal, 7 painted steel, 8 bare metal, 9 terminal glass,
// 10 tower cab glass, 11 pavement / plaza, 12 park lawn.

uniform float night = 0.0;
uniform float lit_fraction = 0.42;

varying vec3 wnrm;
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

void vertex() {
	wnrm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	int style = int(UV2.x + 0.5);
	float seed = UV2.y;
	vec3 tint = COLOR.rgb;
	vec3 albedo = tint;
	float rough = 0.85;
	float metal = 0.0;
	vec3 emit = vec3(0.0);
	float spec = 0.5;

	if (wnrm.y > 0.7 || style >= 11) {
		// Roofs and ground slabs.
		vec2 p = UV;
		float n = vnoise(p * 0.35) * 0.6 + vnoise(p * 3.0) * 0.4;
		if (style == 12) {
			albedo = vec3(0.05, 0.085, 0.03) * (0.8 + 0.4 * n);
		} else if (style == 11) {
			vec2 tile = fract(p / 3.0);
			float joint = step(0.96, max(tile.x, tile.y));
			albedo = vec3(0.12, 0.118, 0.112) * (0.85 + 0.25 * n) * (1.0 - joint * 0.35);
		} else if (style == 6 || style == 7 || style == 8) {
			albedo = tint * (0.85 + 0.2 * n);
			metal = 0.5;
			rough = 0.5;
		} else {
			float r = hash12(vec2(seed, 1.7));
			vec3 roof = mix(vec3(0.16, 0.16, 0.155), vec3(0.075, 0.075, 0.08), r);
			albedo = roof * (0.8 + 0.35 * n);
			rough = 0.9;
		}
	} else {
		// Facade window grid.
		float col_w = 1.5;
		float floor_h = 3.8;
		vec2 win = vec2(0.92, 0.72);     // window fraction of the cell (x, y)
		vec3 glass = vec3(0.08, 0.11, 0.14);
		float glass_metal = 0.7;
		bool has_windows = true;
		if (style == 0 || style == 9) {
			col_w = 1.5; win = vec2(0.96, 0.78);
			glass = mix(vec3(0.10, 0.14, 0.17), vec3(0.13, 0.15, 0.15), hash12(vec2(seed, 3.0))) * mix(vec3(1.0), tint, 0.5);
		} else if (style == 1) {
			col_w = 1.8; win = vec2(0.95, 0.5);
			glass = vec3(0.06, 0.08, 0.1);
		} else if (style == 2) {
			col_w = 3.4; floor_h = 3.1; win = vec2(0.42, 0.52);
			glass = vec3(0.05, 0.06, 0.07); glass_metal = 0.3;
		} else if (style == 3) {
			col_w = 1.25; win = vec2(0.8, 0.86);
			glass = vec3(0.05, 0.065, 0.075); glass_metal = 0.75;
		} else if (style == 4) {
			col_w = 2.6; floor_h = 4.0; win = vec2(0.6, 0.62);
			glass = vec3(0.06, 0.075, 0.09);
		} else if (style == 10) {
			col_w = 2.5; floor_h = 100.0; win = vec2(0.94, 0.98);
			glass = vec3(0.12, 0.16, 0.16);
		} else {
			has_windows = false;
		}

		if (!has_windows) {
			float n = vnoise(UV * vec2(0.2, 0.05)) * 0.5 + vnoise(UV * 2.0) * 0.5;
			albedo = tint * (0.85 + 0.25 * n);
			if (style == 6) {
				float rib = 0.5 + 0.5 * sin(UV.x * 6.2832 / 0.6);
				albedo *= 0.85 + 0.2 * rib;
				metal = 0.45;
				rough = 0.45;
			} else if (style == 7) {
				metal = 0.3;
				rough = 0.45;
			} else if (style == 8) {
				metal = 0.8;
				rough = 0.35;
			} else {
				// Concrete: board marks and stains.
				albedo *= 0.92 + 0.1 * step(0.5, fract(UV.y / 1.2));
				albedo *= 1.0 - 0.15 * smoothstep(0.6, 1.0, vnoise(vec2(UV.x * 0.5, UV.y * 0.05)));
			}
		} else {
			vec2 cell = vec2(UV.x / col_w, UV.y / floor_h);
			vec2 id = floor(cell);
			vec2 f = fract(cell);
			float aa = clamp(1.0 - 1.5 * max(fwidth(cell.x), fwidth(cell.y)), 0.0, 1.0);
			vec2 m = (1.0 - win) * 0.5;
			float wx = smoothstep(m.x - 0.02, m.x + 0.02, f.x) * (1.0 - smoothstep(1.0 - m.x - 0.02, 1.0 - m.x + 0.02, f.x));
			float wy = smoothstep(m.y * 1.4 - 0.02, m.y * 1.4 + 0.02, f.y) * (1.0 - smoothstep(1.0 - m.y * 0.6 - 0.02, 1.0 - m.y * 0.6 + 0.02, f.y));
			float is_win = wx * wy;
			float ground = 1.0 - step(5.0, UV.y);
			if (style != 10 && UV.y < 5.0) {
				// Storefront / lobby glazing at street level.
				is_win = step(0.08, fract(UV.x / 4.0)) * step(0.3, UV.y) * step(UV.y, 4.3);
			}
			// Average facade for distant / minified views.
			float avg_win = win.x * win.y;
			is_win = mix(avg_win, is_win, aa);
			float r = hash12(id + seed * 17.0);
			float r2 = hash12(id.yx + seed * 5.0);
			vec3 g = glass * (0.9 + 0.2 * r2);
			// Blinds / interior variation.
			g = mix(g, vec3(0.2, 0.19, 0.17), step(0.94, r) * 0.5 * aa);
			vec3 wall = tint * (0.9 + 0.15 * vnoise(UV * vec2(0.1, 0.4)));
			if (style == 0 || style == 9 || style == 3) wall = mix(glass * 0.7, tint * 0.35, 0.4);
			albedo = mix(wall, g, is_win);
			metal = mix(0.05, glass_metal, is_win);
			rough = mix(0.8, 0.06 + 0.1 * r2, is_win);
			// Grime streaks down the facade.
			albedo *= 1.0 - 0.12 * vnoise(vec2(UV.x * 0.4, UV.y * 0.02 + seed));
			// Night: some windows lit with warm or cool interiors; lobbies all lit.
			float lit_chance = lit_fraction * (1.0 - 0.3 * smoothstep(60.0, 300.0, UV.y));
			float lit = step(r, lit_chance);
			lit = max(lit, ground);
			if (style == 10) lit = 1.0;
			vec3 lamp = mix(vec3(1.0, 0.72, 0.42), vec3(0.85, 0.9, 1.0), step(0.6, hash12(id * 1.3 + seed)));
			float lit_avg = lit_chance;
			float lit_v = mix(lit_avg, lit, aa);
			emit = lamp * is_win * lit_v * night * (1.2 + 1.6 * r2);
		}
	}

	ALBEDO = albedo;
	ROUGHNESS = rough;
	METALLIC = metal;
	SPECULAR = spec;
	EMISSION = emit;
}
