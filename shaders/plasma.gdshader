shader_type spatial;
// Re-entry plasma on the bow shock shell (rocket_view.gd _bow_shock_mesh):
// VERTEX.y +0.5 = apex just ahead of the leading end, -0.5 = far downstream.
// Like the footage of real capsules: the glow sits in the shock layer in front
// of the heat shield (white-hot to orange-pink), the sides along the hull are
// faint, and behind the craft a wake of glowing gas streams away in streaks.
// Everything flows downstream; nothing turns around the axis.
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled;

uniform float power = 0.0;    // 0..1
uniform float body_d = 0.3;   // where the craft ends, as a fraction downstream
uniform sampler2D noise_tex : hint_default_white, filter_linear_mipmap, repeat_enable;

varying float d;

void vertex() {
	d = 0.5 - VERTEX.y;   // 0 at the apex .. 1 at the tail
	// Behind the craft the wake converges instead of widening further.
	VERTEX.xz *= mix(1.0, 0.45, smoothstep(body_d, 1.0, d));
}

void fragment() {
	float t = TIME;
	float ndv = clamp(abs(dot(NORMAL, VIEW)), 0.0, 1.0);
	float edge = 1.0 - ndv;   // silhouette of the shell = longest path through the glow
	// Streaks: stretched along the flow, carried downstream fast.
	float s1 = texture(noise_tex, vec2(UV.x * 9.0, d * 0.35 - t * 1.4)).r;
	float s2 = texture(noise_tex, vec2(UV.x * 21.0 + 0.4, d * 0.8 - t * 3.3)).r;
	float streak = smoothstep(0.35, 0.85, s1 * 0.6 + s2 * 0.4);
	float flick = 0.85 + 0.3 * texture(noise_tex, vec2(UV.x * 2.0, t * 0.9)).r;

	// Shock layer in front of the shield: thin and very bright.
	float soft = smoothstep(0.0, 0.35, ndv);   // no hard line at the shell's outline
	float cap = exp(-d / 0.035) * (0.35 + 0.6 * edge) * soft;
	// Along the hull: a faint sheath, a little brighter at the silhouette.
	float sheath = 0.1 * (1.0 - smoothstep(0.0, body_d * 1.2, d)) * edge * soft;
	// Wake behind the craft: streaky, fading downstream.
	float wake_on = smoothstep(body_d * 0.7, body_d * 1.15, d);
	float wake = wake_on * exp(-(d - body_d) * 2.6) * (0.2 + 0.9 * streak) * pow(ndv, 1.6);
	float tail = 1.0 - smoothstep(0.75, 1.0, d);

	vec3 white = vec3(1.0, 0.92, 0.85);
	vec3 orange = vec3(1.0, 0.45, 0.15);
	vec3 pink = vec3(0.95, 0.35, 0.55);
	vec3 col = mix(white, vec3(1.0, 0.55, 0.4), 0.6) * cap * 1.25 + mix(orange, pink, 0.35) * sheath
		+ mix(orange, pink, smoothstep(0.0, 0.6, d - body_d)) * wake;
	ALBEDO = col * tail * flick * power * 1.6;
}
