shader_type spatial;
// Gas giant: latitude bands warped by turbulence noise (UV = lon/lat like the maps).

uniform vec3 color_a : source_color = vec3(0.85, 0.75, 0.6);
uniform vec3 color_b : source_color = vec3(0.65, 0.5, 0.38);
uniform vec3 color_c : source_color = vec3(0.95, 0.92, 0.85);
uniform float bands = 14.0;
uniform float warp = 0.035;
uniform float contrast = 1.0;
uniform sampler2D turbulence : hint_default_black, filter_linear_mipmap, repeat_enable;

void fragment() {
	vec2 uv = UV;
	float t1 = texture(turbulence, uv * vec2(3.0, 2.0)).r - 0.5;
	float t2 = texture(turbulence, uv * vec2(11.0, 7.0) + vec2(0.3, 0.1)).r - 0.5;
	float lat = uv.y + t1 * warp + t2 * warp * 0.35;
	float b1 = sin(lat * bands * 3.14159);
	float b2 = sin(lat * bands * 7.3 + 1.7);
	vec3 col = mix(color_b, color_a, smoothstep(-0.6, 0.6, b1 * contrast));
	col = mix(col, color_c, smoothstep(0.55, 1.0, b2) * 0.35);
	// Darker towards the poles.
	float pole = abs(uv.y - 0.5) * 2.0;
	col *= mix(1.0, 0.72, smoothstep(0.6, 1.0, pole));
	ALBEDO = col;
	ROUGHNESS = 0.9;
	SPECULAR = 0.15;
}
