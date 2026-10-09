shader_type spatial;
// Planet surface (globe and ground patch): NASA colour + normal map, water with
// gloss / fake sky reflection / small waves, and close-up detail on the patch
// (UV2 = metres in the patch plane). The environment has reflections disabled,
// so water reflection is faked with a Fresnel term in EMISSION.

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap, repeat_enable;
uniform float normal_strength = 0.6;
uniform bool use_normal_tex = true;

uniform bool has_water = false;
uniform sampler2D water_tex : hint_default_black, filter_linear_mipmap, repeat_enable;
uniform vec3 water_deep : source_color = vec3(0.015, 0.06, 0.16);
uniform vec3 water_shallow : source_color = vec3(0.03, 0.17, 0.3);
uniform vec3 sky_color : source_color = vec3(0.42, 0.58, 0.85);

uniform bool use_detail = false;
uniform sampler2D detail_tex : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform sampler2D detail_normal : hint_normal, filter_linear_mipmap, repeat_enable;
uniform float detail_strength = 0.45;
uniform float detail_normal_strength = 0.6;
uniform sampler2D pebble_tex : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform sampler2D pebble_normal : hint_normal, filter_linear_mipmap, repeat_enable;
uniform float pebble_strength = 0.0;
uniform vec3 detail_tint : source_color = vec3(1.0);   // e.g. greener land on Earth

uniform float land_roughness = 0.9;
// High-resolution colour block (downloaded tiles) over a UV rectangle of the map.
uniform sampler2D hd_tex : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform vec4 hd_rect = vec4(0.0, 0.0, 0.0, 0.0);   // u0, v0, du, dv (du = 0: none)
uniform bool use_slope = false;                         // patch: COLOR.r = slope 0..1
uniform vec3 slope_tint : source_color = vec3(0.75);

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
			col = mix(col, texture(hd_tex, hu).rgb, edge);
		}
	}
	float water = has_water ? smoothstep(0.35, 0.65, texture(water_tex, UV).r) : 0.0;
	vec3 nm = use_normal_tex ? texture(normal_tex, UV).rgb : vec3(0.5, 0.5, 1.0);
	float dist = length(VERTEX);

	if (use_detail) {
		// Close-up detail in three scales (40 m, 6 m, 1.2 m) plus a pebble /
		// regolith layer, each fading out as it gets too small on screen.
		float fade_far = 1.0 - smoothstep(1500.0, 9000.0, dist);
		float fade_mid = 1.0 - smoothstep(150.0, 900.0, dist);
		float fade_near = 1.0 - smoothstep(25.0, 160.0, dist);
		float d1 = texture(detail_tex, UV2 / 45.0).r;
		float d2 = texture(detail_tex, UV2 / 6.0 + vec2(0.37, 0.71)).r;
		float d3 = texture(detail_tex, UV2 / 1.2 + vec2(0.13, 0.29)).r;
		float pb = texture(pebble_tex, UV2 / 2.5).r;
		float d = 1.0;
		d *= mix(1.0, 0.62 + 0.76 * d1, detail_strength * fade_far);
		d *= mix(1.0, 0.7 + 0.6 * d2, detail_strength * fade_mid);
		d *= mix(1.0, 0.78 + 0.44 * d3, detail_strength * fade_near);
		// Pebbles: dark gaps between lighter stones.
		d *= mix(1.0, 0.72 + 0.4 * smoothstep(0.15, 0.6, pb), pebble_strength * fade_near);
		col *= d * detail_tint;
		// Bumps: 9 m and 1.7 m noise normals, plus pebble normals up close.
		vec3 dn = texture(detail_normal, UV2 / 9.0).rgb * 2.0 - 1.0;
		vec3 dn2 = texture(detail_normal, UV2 / 1.7 + vec2(0.2, 0.6)).rgb * 2.0 - 1.0;
		vec3 dn3 = texture(pebble_normal, UV2 / 2.5).rgb * 2.0 - 1.0;
		float near = (1.0 - smoothstep(60.0, 600.0, dist)) * detail_normal_strength;
		vec3 b = nm * 2.0 - 1.0;
		b.xy += (dn.xy * 0.7 + dn2.xy * 0.5) * near + dn3.xy * 0.6 * pebble_strength * fade_near;
		nm = normalize(b) * 0.5 + 0.5;
		// Waves on water: two scrolling layers.
		if (water > 0.0) {
			vec3 w1 = texture(detail_normal, UV2 / 40.0 + vec2(TIME * 0.006, TIME * 0.002)).rgb * 2.0 - 1.0;
			vec3 w2 = texture(detail_normal, UV2 / 13.0 - vec2(TIME * 0.004, -TIME * 0.007)).rgb * 2.0 - 1.0;
			vec3 wn = normalize(vec3((w1.xy + w2.xy) * 0.35, 1.0)) * 0.5 + 0.5;
			nm = mix(nm, wn, water);
		}
	} else {
		nm = mix(nm, vec3(0.5, 0.5, 1.0), water);   // calm water seen from orbit
	}

	if (use_slope) {
		// Steep ground: bare, darker rock (crater walls, cliffs).
		float sl = smoothstep(0.18, 0.5, COLOR.r);
		col = mix(col, col * slope_tint, sl * (1.0 - water));
	}

	// The Blue Marble ocean is very dark: brighten it, keeping the bathymetry
	// shading of the map (shallow shelves lighter), and lift it toward sea blue.
	float shelf = clamp(dot(col, vec3(0.33)) * 5.0, 0.0, 1.0);
	vec3 sea = col * 1.9 + mix(water_deep, water_shallow, shelf) * 0.6;
	col = mix(col, sea, water);

	ALBEDO = col;
	ROUGHNESS = mix(land_roughness, 0.08, water);
	SPECULAR = mix(0.25, 0.7, water);
	NORMAL_MAP = nm;
	NORMAL_MAP_DEPTH = use_normal_tex || use_detail ? normal_strength : 0.0;
	// Fake sky reflection on water (Fresnel); stronger at grazing angles.
	float fres = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 4.0);
	EMISSION = water * sky_color * (0.03 + 0.55 * fres);
}
