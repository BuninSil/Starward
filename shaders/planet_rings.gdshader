shader_type spatial;
render_mode cull_disabled, blend_mix, depth_draw_opaque;
// Planetary rings on a flat annulus mesh; UV.x = 0 inner edge .. 1 outer edge.

uniform vec3 ring_color : source_color = vec3(0.86, 0.8, 0.66);
uniform float opacity = 0.85;
uniform sampler2D bands_tex : hint_default_white, filter_linear, repeat_enable;

void fragment() {
	float r = UV.x;
	float b = texture(bands_tex, vec2(r * 2.3, 0.5)).r;
	float gap = smoothstep(0.52, 0.55, r) * (1.0 - smoothstep(0.58, 0.61, r));   // Cassini division
	float a = opacity * (0.35 + 0.65 * b) * (1.0 - gap * 0.9);
	a *= smoothstep(0.0, 0.04, r) * (1.0 - smoothstep(0.96, 1.0, r));
	ALBEDO = ring_color * (0.75 + 0.4 * b);
	ALPHA = a;
	ROUGHNESS = 1.0;
	SPECULAR = 0.0;
}
