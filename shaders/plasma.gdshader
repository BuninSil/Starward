shader_type spatial;
// Re-entry plasma sheath: a glowing shell from the leading end of the craft
// trailing downstream. VERTEX.y: -0.5 back .. +0.5 front (mesh scaled so +Y
// points along the velocity).
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled;

uniform float power = 0.0;   // 0..1
uniform sampler2D noise_tex : hint_default_white, filter_linear_mipmap, repeat_enable;

varying float h;

void vertex() {
	h = VERTEX.y + 0.5;
}

void fragment() {
	float rim = pow(1.0 - abs(dot(NORMAL, VIEW)), 1.5);
	float n = texture(noise_tex, vec2(UV.x * 3.0 + TIME * 0.7, h * 1.5 - TIME * 3.1)).r;
	float n2 = texture(noise_tex, vec2(UV.x * 7.0 - TIME * 0.4, h * 3.0 - TIME * 5.3)).r;
	float a = pow(h, 1.8) * (0.35 + 0.65 * rim) * (0.55 + 0.6 * n * n2 * 1.6);
	vec3 hot = vec3(1.0, 0.85, 0.6);
	vec3 mid = vec3(1.0, 0.42, 0.12);
	vec3 tail = vec3(0.85, 0.22, 0.35);
	vec3 c = mix(tail, mix(mid, hot, smoothstep(0.75, 1.0, h)), smoothstep(0.1, 0.7, h));
	ALBEDO = c * a * power * 2.2;
}
