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
uniform vec3 detail_tint : source_color = vec3(1.0);   // e.g. greener land on Earth

uniform float land_roughness = 0.9;

void fragment() {
	vec3 col = texture(albedo_tex, UV).rgb;
	float water = has_water ? smoothstep(0.35, 0.65, texture(water_tex, UV).r) : 0.0;
	vec3 nm = use_normal_tex ? texture(normal_tex, UV).rgb : vec3(0.5, 0.5, 1.0);
	float dist = length(VERTEX);

	if (use_detail) {
		// Two octaves of grey noise at ~45 m and ~6 m, fading out with distance.
		float fade = 1.0 - smoothstep(1500.0, 9000.0, dist);
		float d1 = texture(detail_tex, UV2 / 45.0).r;
		float d2 = texture(detail_tex, UV2 / 6.0 + vec2(0.37, 0.71)).r;
		float d = mix(1.0, 0.62 + 0.76 * (0.55 * d1 + 0.45 * d2), detail_strength * fade);
		col *= d * detail_tint;
		// Close-up bumps (land) from a noise normal map.
		vec3 dn = texture(detail_normal, UV2 / 9.0).rgb * 2.0 - 1.0;
		vec3 dn2 = texture(detail_normal, UV2 / 1.7 + vec2(0.2, 0.6)).rgb * 2.0 - 1.0;
		float near = (1.0 - smoothstep(60.0, 600.0, dist)) * detail_normal_strength;
		vec3 b = nm * 2.0 - 1.0;
		b.xy += (dn.xy * 0.7 + dn2.xy * 0.5) * near;
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
