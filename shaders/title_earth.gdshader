shader_type spatial;
// Title-screen Earth: NASA colour map, oceans lifted to the blue they look from
// orbit (Rayleigh scattering over dark water) with a sun glint, soft limb haze.

uniform sampler2D color_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D water_tex : hint_default_black, filter_linear_mipmap, repeat_enable;
uniform vec3 ocean_tint = vec3(0.025, 0.095, 0.25);   // linear
uniform vec3 haze = vec3(0.25, 0.45, 0.9);          // linear


void fragment() {
	vec3 c = texture(color_tex, UV).rgb;
	float w = smoothstep(0.35, 0.65, texture(water_tex, UV).r);
	// Ocean: keep the texture's depth detail, lift it towards scattered blue.
	c = mix(c, c * 0.6 + ocean_tint, w);
	// Thicker air at the limb: blue haze over everything.
	float limb = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 2.5);
	ALBEDO = mix(c, haze, limb * 0.55);
	NORMAL_MAP = texture(normal_tex, UV).rgb;
	NORMAL_MAP_DEPTH = 0.6 * (1.0 - w);
	ROUGHNESS = mix(0.85, 0.28, w);
	SPECULAR = mix(0.2, 0.6, w);
}
