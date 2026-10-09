shader_type spatial;
// Planet surface (globe and ground patch): NASA colour + normal map, water with
// gloss / fake sky reflection / small waves, and close-up ground on the patch
// (UV2 = metres in the patch plane: x east, y south). The environment has
// reflections disabled, so water reflection is faked with a Fresnel term.
//
// Close-up ground ("high" detail level):
//  * colour: the map's large-scale variation, rescaled to the body's real albedo
//    and recoloured toward its ground colour; soft macro variation (hundreds of
//    metres, own seed per body);
//  * four materials per body mixed by masks (slope, crater rims / ejecta from
//    vertex colour, noise) with height blending (ragged edges, not gradients):
//    airless: fine regolith, compacted regolith, gravel, rock outcrop;
//    Mars:    dust, wind ripples, gravel, layered rock plates;
//  * two scales of the packed ground textures with different UV rotations; the
//    near one stochastically tiled (two reads at random offsets chosen by a
//    low-frequency noise, Quilez-style), so no repeat reads near or far;
//  * small crater decals (0.3–8 m) computed procedurally, with shadows inside
//    at low sun, plus micro shadows of grains and pebbles.
// "Low" detail level: only the macro variation and one plain layer.

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap, repeat_enable;
uniform float normal_strength = 0.6;
uniform bool use_normal_tex = true;

uniform bool has_water = false;
uniform sampler2D water_tex : hint_default_black, filter_linear_mipmap, repeat_enable;
uniform vec3 water_deep : source_color = vec3(0.015, 0.06, 0.16);
uniform vec3 water_shallow : source_color = vec3(0.03, 0.17, 0.3);
uniform vec3 sky_color : source_color = vec3(0.42, 0.58, 0.85);

// Real albedo: the map's mean linear luminance is scaled to albedo_target and
// recoloured toward ground_color (whose luminance is ~albedo_target).
uniform float albedo_target = -1.0;     // <= 0: keep the map colours
uniform float map_mean = 0.3;
uniform vec3 ground_color = vec3(0.13);   // linear
uniform float recolor = 0.0;

uniform bool use_detail = false;
uniform int detail_level = 1;           // 0 low, 1 high
// Packed ground textures (planet_view.gd _ground_textures):
//   pack:   R fine speckle, G cracked rock (ridged), B soft bumps, A pebbles;
//   normal: RG fine ground, BA gravel;  normal2: RG rock, BA soft bumps.
uniform sampler2D ground_pack : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D ground_pack_normal : hint_default_black, filter_linear_mipmap, repeat_enable;
uniform sampler2D ground_pack_normal2 : hint_default_black, filter_linear_mipmap, repeat_enable;
uniform float detail_strength = 0.85;
uniform int ground_kind = 0;            // 0 airless / generic, 1 Mars
uniform vec2 macro_seed = vec2(0.0);
uniform float macro_amp = 0.3;
uniform vec3 macro_tint = vec3(1.0);   // hue of the brighter macro patches
uniform vec4 mat_amount = vec4(1.0, 0.5, 0.5, 0.6);  // fine, smooth/ripples, gravel, rock outcrops
uniform vec3 rock_tint = vec3(0.8);         // multipliers
uniform vec3 gravel_tint = vec3(0.9);
uniform float crater_decals = 0.0;
uniform vec2 wind_dir = vec2(0.8, 0.6);
uniform vec3 detail_tint = vec3(1.0);   // e.g. greener land on Earth

uniform float land_roughness = 0.9;
// High-resolution colour block (downloaded tiles) over a UV rectangle of the map.
uniform sampler2D hd_tex : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform vec4 hd_rect = vec4(0.0, 0.0, 0.0, 0.0);   // u0, v0, du, dv (du = 0: none)
uniform bool use_slope = false;   // patch: COLOR.r slope, COLOR.g ejecta, COLOR.b crater rims
uniform vec3 sun_local = vec3(0.0, 1.0, 0.0);   // patch: toward the sun, patch axes
// Regolith reflectance (0 = Lambert): Lommel–Seeliger + opposition surge, the
// reason airless ground stays bright at a low sun and looks "Apollo-like".
uniform float regolith = 0.0;

varying float v_shade;

const mat2 ROT_MID = mat2(vec2(0.80, 0.60), vec2(-0.60, 0.80));
const mat2 ROT_MACRO1 = mat2(vec2(0.28, 0.96), vec2(-0.96, 0.28));
const mat2 ROT_MACRO2 = mat2(vec2(-0.71, 0.70), vec2(-0.70, -0.71));

vec4 hash42(vec2 p) {
	vec4 p4 = fract(vec4(p.xyxy) * vec4(0.1031, 0.1030, 0.0973, 0.1099));
	p4 += dot(p4, p4.wzxy + 33.33);
	return fract((p4.xxyz + p4.yzzw) * p4.zywx);
}

// Two reads of a texture at random offsets picked by the noise index k, blended
// with weight w (shared by all textures read with the same offsets).
vec4 stoch(sampler2D s, vec2 uv, vec2 dx, vec2 dy, vec2 oa, vec2 ob, float w) {
	return mix(textureGrad(s, uv + oa, dx, dy), textureGrad(s, uv + ob, dx, dy), w);
}

// Bowl crater with a rim; x = distance / radius. Height in units of depth.
float crater_z(float x, float young) {
	float b = clamp(1.0 - x * x, 0.0, 1.0);
	float bowl = -b * b * (3.0 - 2.0 * b);                 // rounded floor and walls
	float rim = exp(-pow((x - 1.0) / mix(0.35, 0.2, young), 2.0)) * mix(0.12, 0.25, young);
	return bowl + rim;
}

// One layer of small craters (below the terrain mesh resolution), at most one
// per cell and fully inside it, so a single cell is evaluated. Outlines are
// irregular; most craters are old and shallow. Returns gradient (xy), shade (z)
// and albedo change (w).
vec4 crater_layer(vec2 uv, float cell, float fill, float seed, vec2 sun_h, float tan_e) {
	vec2 c = uv / cell;
	vec2 id = floor(c);
	vec4 h = hash42(id + seed);
	if (h.x > fill) {
		return vec4(0.0);
	}
	float young = step(h.y, 0.1);
	float r = 0.1 + 0.25 * h.z * h.z;                  // radius, cells (power law-ish)
	vec2 ctr = 0.5 + (h.wz - 0.5) * (1.0 - 2.8 * r);   // stays inside the cell
	vec2 o = c - id - ctr;
	float ang = atan(o.y, o.x);
	float wob = 1.0 + 0.1 * sin(ang * 3.0 + h.w * 6.3) + 0.06 * sin(ang * 5.0 + h.y * 6.3);
	float rr = r * wob;
	float x = length(o) / rr;
	if (x > 1.4) {
		return vec4(0.0);
	}
	float depth = rr * cell * mix(0.07 + 0.1 * h.w, 0.38, young);   // metres
	float dz = (crater_z(x + 0.02, young) - crater_z(x - 0.02, young)) / 0.04 * depth / (rr * cell);
	vec2 grad = x > 1e-3 ? o / (x * rr) * dz : vec2(0.0);
	// Shadow: is the terrain higher toward the sun than the sun ray?
	float z0 = crater_z(x, young) * depth;
	float shade = 0.0;
	for (int i = 1; i <= 2; i++) {
		float L = float(i) * 0.6 * rr * cell;
		vec2 q = o + sun_h * (L / cell);
		float zq = crater_z(length(q) / rr, young) * depth;
		shade = max(shade, smoothstep(0.0, 0.1 * depth + 0.01, zq - z0 - L * tan_e));
	}
	float bright = young * (x > 0.9 ? 0.15 * exp(-(x - 1.0) * 4.0) : -0.04);
	return vec4(grad, shade * smoothstep(1.4, 1.0, x), bright);
}

void fragment() {
	vec3 col = texture(albedo_tex, UV).rgb;
	if (hd_rect.z > 0.0) {
		float du = UV.x - hd_rect.x;
		du -= floor(du);                       // wrap across the date line
		vec2 hu = vec2(du / hd_rect.z, (UV.y - hd_rect.y) / hd_rect.w);
		if (hu.x >= 0.0 && hu.x <= 1.0 && hu.y >= 0.0 && hu.y <= 1.0) {
			// Fade in from the block edges so the seam to the global map is soft.
			vec2 e = min(hu, 1.0 - hu);
			float edge = smoothstep(0.0, 0.08, min(e.x, e.y));
			// The tiles come from other sources than the global map (different
			// stretch / brightness): use them as relative detail over the map's
			// own brightness (tile / its local mean from a small mip level).
			vec3 hd = texture(hd_tex, hu).rgb;
			vec3 hd_mean = textureLod(hd_tex, hu, 6.0).rgb;
			col = mix(col, col * clamp(hd / max(hd_mean, vec3(0.01)), vec3(0.0), vec3(3.0)), edge);
		}
	}
	if (albedo_target > 0.0) {
		// Relative brightness, compressed (real albedo contrasts are ~2:1).
		float rel = clamp(pow(dot(col, vec3(0.2126, 0.7152, 0.0722)) / map_mean, 0.6), 0.45, 1.7);
		vec3 hue = col / max(dot(col, vec3(0.2126, 0.7152, 0.0722)), 1e-3);
		col = mix(hue * albedo_target * rel, ground_color * rel, recolor);
	}
	float water = has_water ? smoothstep(0.35, 0.65, texture(water_tex, UV).r) : 0.0;
	vec3 nm = use_normal_tex ? texture(normal_tex, UV).rgb : vec3(0.5, 0.5, 1.0);
	float dist = length(VERTEX);
	float shade = 0.0;

	if (use_detail && dist < 20000.0) {
		float fade_far = 1.0 - smoothstep(6000.0, 20000.0, dist);
		float fade_mid = 1.0 - smoothstep(600.0, 3000.0, dist);
		float fade_near = 1.0 - smoothstep(25.0, 120.0, dist);
		vec2 ddx = dFdx(UV2);
		vec2 ddy = dFdy(UV2);
		float slope = use_slope ? COLOR.r : 0.0;
		float ejecta = use_slope ? COLOR.g : 0.0;
		float rims = use_slope ? COLOR.b : 0.0;

		// Soft macro variation: two rotated scales (~200 m and ~700 m features).
		float m1 = texture(ground_pack, ROT_MACRO1 * UV2 / 1300.0 + macro_seed).b;
		float m2 = texture(ground_pack, ROT_MACRO2 * UV2 / 4200.0 + macro_seed.yx).b;
		float mv = (m1 - 0.5) * 0.65 + (m2 - 0.5) * 0.5;
		col *= 1.0 + mv * macro_amp * fade_far;
		col = mix(col, col * macro_tint, clamp(m2 * 1.6 - 0.5, 0.0, 1.0) * fade_far);
		col *= 1.0 + ejecta * 0.55;   // bright ejecta and rays of young craters

		// Mid scale: rotated, plain (also the noise index for the stochastic layer).
		vec2 umid = ROT_MID * UV2 / 23.0 + macro_seed * 3.0;
		vec2 mdx = ROT_MID * ddx / 23.0;
		vec2 mdy = ROT_MID * ddy / 23.0;
		vec4 pm = textureGrad(ground_pack, umid, mdx, mdy);
		vec4 pn = pm;          // near-scale pack (falls back to mid)
		vec4 n1 = vec4(0.5);   // fine | gravel normals
		vec4 n2 = vec4(0.5);   // rock | bumps normals
		float near_w = 0.0;
		vec2 sun_h = sun_local.xz / max(length(sun_local.xz), 1e-4);   // horizontal, unit
		float tan_e = sun_local.y / max(length(sun_local.xz), 1e-3);
		vec2 near_off_a = vec2(0.0);
		vec2 near_off_b = vec2(0.0);
		float near_mix = 0.0;
		if (detail_level > 0 && dist < 3000.0) {
			// Mid-scale normals, rotated back to the patch axes.
			vec4 mn1 = textureGrad(ground_pack_normal, umid, mdx, mdy) * 2.0 - 1.0;
			vec4 mn2 = textureGrad(ground_pack_normal2, umid, mdx, mdy) * 2.0 - 1.0;
			mat2 back = transpose(ROT_MID);
			n1 = vec4(back * mn1.xy, back * mn1.zw) * 0.5 + 0.5;
			n2 = vec4(back * mn2.xy, back * mn2.zw) * 0.5 + 0.5;
		}
		if (detail_level > 0 && dist < 120.0) {
			// Near scale, stochastically tiled (3.2 m texture repeat).
			float l = pm.b * 9.0;
			float ia = floor(l);
			near_off_a = sin(vec2(3.0, 7.0) * ia);
			near_off_b = sin(vec2(3.0, 7.0) * (ia + 1.0));
			vec2 un = UV2 / 3.2;
			vec2 ndx = ddx / 3.2;
			vec2 ndy = ddy / 3.2;
			vec4 a = textureGrad(ground_pack, un + near_off_a, ndx, ndy);
			vec4 b = textureGrad(ground_pack, un + near_off_b, ndx, ndy);
			near_mix = smoothstep(0.2, 0.8, fract(l) - 0.1 * dot(a - b, vec4(1.0)));
			vec4 p_near = mix(a, b, near_mix);
			near_w = fade_near;
			pn = mix(pm, p_near, near_w);
			vec4 q1 = stoch(ground_pack_normal, un, ndx, ndy, near_off_a, near_off_b, near_mix);
			vec4 q2 = stoch(ground_pack_normal2, un, ndx, ndy, near_off_a, near_off_b, near_mix);
			n1 = mix(n1, q1, near_w);
			n2 = mix(n2, q2, near_w);
		}

		// --- Material masks + height blend --------------------------------------
		float mb = pm.b;
		float cov_fine = 0.55 * mat_amount.x;
		float cov_smooth = mat_amount.y * smoothstep(0.35, 0.75, 1.0 - m1) * (1.0 - smoothstep(0.08, 0.25, slope));
		float cov_gravel = mat_amount.z * (smoothstep(0.55, 0.85, mb) * 0.7 + ejecta * 0.9 + rims * 0.5 + slope * 0.6);
		float cov_rock = mat_amount.w * (smoothstep(0.62, 0.9, m1) * 0.8 + smoothstep(0.66, 0.85, mb) * 0.3)
			+ smoothstep(0.2, 0.45, slope) * 1.2 + rims * 0.9;
		cov_rock *= 1.0 - water;
		// Each material's own height lets it poke through the others at the edge.
		float hf = pn.r * 0.4 + pn.b * 0.6;
		float hs = pn.b;
		float hg = pn.a;
		float hr = pn.g;
		vec4 hb = vec4(cov_fine, cov_smooth, cov_gravel, cov_rock) + vec4(hf, hs, hg, hr) * 0.35;
		float hmax = max(max(hb.x, hb.y), max(hb.z, hb.w));
		vec4 w = max(hb - (hmax - 0.12), vec4(0.0));
		w /= max(w.x + w.y + w.z + w.w, 1e-4);

		// --- Material colours (relative to the map/ground colour) -----------------
		float lum = max(dot(col, vec3(0.333)), 1e-3);
		vec3 base = col;
		float speck = 0.78 + 0.44 * pn.r;
		// Cavities: lower ground darker (mid bumps + near grain height).
		float cav = mix(0.82 + 0.36 * pm.b, 1.0, 0.0) * mix(1.0, 0.8 + 0.4 * (pn.r * 0.4 + pn.b * 0.6), near_w);
		vec3 c_fine = base * mix(1.0, speck * cav, fade_mid) * detail_tint;
		vec3 c_smooth;
		vec3 c_gravel = base * gravel_tint * mix(1.0, 0.82 + 0.4 * pn.a, fade_mid);
		vec3 c_rock;
		vec2 ripple_grad = vec2(0.0);
		if (ground_kind == 1) {
			// Mars: smooth light dust; ripples of coarser sand; layered rock plates.
			float ph = dot(UV2, wind_dir) / 0.55 * 6.2832 + pm.b * 9.0 + pn.r * 0.6;
			float s = sin(ph);
			float crest = pow(0.5 + 0.5 * s, 3.0);
			float ph2 = dot(UV2, vec2(-wind_dir.y, wind_dir.x) * 0.3 + wind_dir) / 3.8 * 6.2832 + m1 * 14.0;
			float crest2 = pow(0.5 + 0.5 * sin(ph2), 2.0);
			ripple_grad = wind_dir * (1.5 * pow(0.5 + 0.5 * s, 2.0) * cos(ph) * 6.2832 / 0.55 * 0.012 * fade_near
				+ cos(ph2) * crest2 * 6.2832 / 3.8 * 0.05 * fade_mid);
			c_smooth = base * (0.97 + 0.08 * crest * fade_near + 0.05 * crest2 * fade_mid);
			float strata = 0.5 + 0.5 * sin((UV2.y * 0.9 + UV2.x * 0.25) * 2.4 + pn.g * 3.0 + m1 * 20.0);
			c_rock = base * rock_tint * (0.62 + 0.38 * pn.g) * (0.88 + 0.2 * strata);
		} else {
			c_smooth = base * 0.93 * mix(1.0, 0.96 + 0.08 * pn.b, fade_mid);
			c_rock = base * rock_tint * (0.5 + 0.55 * pn.g);
		}
		vec3 detail_col = c_fine * w.x + c_smooth * w.y + c_gravel * w.z + c_rock * w.w;
		col = mix(col, detail_col, detail_strength * fade_far);

		// --- Normals ------------------------------------------------------------------
		vec2 nf = (n1.xy * 2.0 - 1.0);
		vec2 ng = (n1.zw * 2.0 - 1.0);
		vec2 nr = (n2.xy * 2.0 - 1.0);
		vec2 nbm = (n2.zw * 2.0 - 1.0);
		vec2 bump = (nf * (w.x * 0.8) + nbm * (w.y * 0.45) + ng * (w.z * 1.1) + nr * (w.w * 1.2)) * 2.2;
		vec3 bn = nm * 2.0 - 1.0;
		bn.xy += bump * fade_mid;
		// Ripple / crater slopes -> tangent-space normal (x east, y north).
		vec2 g = ripple_grad * w.y;
		vec4 cr = vec4(0.0);
		if (crater_decals > 0.0 && detail_level > 0) {
			mat2 ra = mat2(vec2(0.6, 0.8), vec2(-0.8, 0.6));
			mat2 rb = mat2(vec2(0.96, -0.28), vec2(0.28, 0.96));
			if (dist < 30.0) {
				vec4 c1 = crater_layer(ra * UV2, 1.6, 0.3 * crater_decals, 3.1, ra * sun_h, tan_e)
					* (1.0 - smoothstep(15.0, 30.0, dist));
				cr = vec4(transpose(ra) * c1.xy, c1.zw);
			}
			if (dist < 90.0) {
				vec4 c2 = crater_layer(rb * UV2, 5.0, 0.22 * crater_decals, 7.7, rb * sun_h, tan_e)
					* (1.0 - smoothstep(50.0, 90.0, dist));
				cr = vec4(cr.xy + transpose(rb) * c2.xy, max(cr.z, c2.z), cr.w + c2.w);
			}
			g += cr.xy;
			col *= 1.0 + cr.w;
			shade = max(shade, cr.z);
		}
		bn.xy += vec2(-g.x, g.y) * 2.0;

		// Micro shadows of grains / pebbles / rock ridges near the camera.
		if (detail_level > 0 && dist < 60.0 && tan_e > 0.0) {
			vec2 un = UV2 / 3.2 + sun_h * (0.05 / 3.2);
			vec4 s = mix(textureGrad(ground_pack, un + near_off_a, ddx / 3.2, ddy / 3.2),
				textureGrad(ground_pack, un + near_off_b, ddx / 3.2, ddy / 3.2), near_mix);
			vec4 hb0 = vec4(hf, hs, hg, hr);
			vec4 hb1 = vec4(s.r * 0.4 + s.b * 0.6, s.b, s.a, s.g);
			float dh = dot(hb1 - hb0, w);
			shade = max(shade, smoothstep(0.02, 0.12, dh - 0.05 * tan_e) * (1.0 - smoothstep(30.0, 60.0, dist)));
		}
		nm = normalize(bn) * 0.5 + 0.5;
		// Waves on water: two scrolling layers of the fine normals.
		if (water > 0.0) {
			vec2 w1 = texture(ground_pack_normal2, UV2 / 40.0 + vec2(TIME * 0.006, TIME * 0.002)).zw * 2.0 - 1.0;
			vec2 w2 = texture(ground_pack_normal2, UV2 / 13.0 - vec2(TIME * 0.004, -TIME * 0.007)).zw * 2.0 - 1.0;
			vec3 wn = normalize(vec3((w1 + w2) * 0.35, 1.0)) * 0.5 + 0.5;
			nm = mix(nm, wn, water);
		}
	} else {
		nm = mix(nm, vec3(0.5, 0.5, 1.0), water);   // calm water seen from orbit
	}

	// The Blue Marble ocean is very dark: brighten it, keeping the bathymetry
	// shading of the map (shallow shelves lighter), and lift it toward sea blue.
	float shelf = clamp(dot(col, vec3(0.33)) * 5.0, 0.0, 1.0);
	vec3 sea = col * 1.9 + mix(water_deep, water_shallow, shelf) * 0.6;
	col = mix(col, sea, water);

	// Crater / grain micro shadows: applied to the sunlight in light().
	v_shade = shade * (1.0 - water);
	ALBEDO = col;
	ROUGHNESS = mix(land_roughness, 0.08, water);
	SPECULAR = mix(use_detail ? 0.06 : 0.25, 0.7, water);   // regolith / dust: no sheen
	NORMAL_MAP = nm;
	NORMAL_MAP_DEPTH = use_normal_tex || use_detail ? normal_strength : 0.0;
	// Fake sky reflection on water (Fresnel); stronger at grazing angles.
	float fres = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 4.0);
	EMISSION = water * sky_color * (0.03 + 0.55 * fres);
}

void light() {
	float ndl = clamp(dot(NORMAL, LIGHT), 0.0, 1.0);
	float ndv = clamp(dot(NORMAL, VIEW), 0.05, 1.0);
	// Lommel–Seeliger, normalised to Lambert at the zenith; opposition surge
	// when the sun is behind the viewer.
	float ls = 2.0 * ndl / (ndl + ndv);
	float phase = acos(clamp(dot(LIGHT, VIEW), -1.0, 1.0));
	float surge = 1.0 + 0.5 * exp(-phase / 0.12);
	float diff = mix(ndl, ls * surge * smoothstep(0.0, 0.05, ndl), regolith);
	DIFFUSE_LIGHT += LIGHT_COLOR * ATTENUATION * diff * (1.0 - 0.9 * v_shade) / PI;
	// Glossy highlight (water): normalised Blinn-Phong from the roughness.
	if (ROUGHNESS < 0.5) {
		float shin = 2.0 / max(ROUGHNESS * ROUGHNESS * ROUGHNESS * ROUGHNESS, 1e-4) - 2.0;
		float nh = clamp(dot(NORMAL, normalize(LIGHT + VIEW)), 0.0, 1.0);
		SPECULAR_LIGHT += LIGHT_COLOR * ATTENUATION * ndl * pow(nh, min(shin, 2000.0)) * (shin + 8.0) / (8.0 * PI) * 0.15;
	}
}
