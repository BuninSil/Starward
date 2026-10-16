shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled;
// Rocket exhaust plume on a cone (rocket_view.gd): UV.y = 0 at the nozzle,
// 1 at the tail. Kerosene/oxygen at sea level: a dazzling white-yellow core
// with shock diamonds right below the nozzle, then a luminous orange body that
// turns turbulent and ragged downstream, fading to dull red. In vacuum the
// plume blooms wide and is almost transparent, bright only at the nozzle.
// The turbulence only flows downstream (nothing spins around the axis).

uniform float throttle = 1.0;
uniform float pressure = 1.0;   // 0 vacuum .. 1 sea level
uniform sampler2D noise_tex : hint_default_white, filter_linear_mipmap, repeat_enable;

varying float v_len;

void vertex() {
	float v = UV.y;
	// The mesh is a straight cone (radius 0.35 .. 1). Shape it: in air the jet
	// stays narrow and widens slowly; in vacuum it blooms out at once.
	float lin = mix(0.35, 1.0, v);
	float air = mix(0.38, 1.0, pow(v, 0.6));
	float vac = mix(0.42, 1.0, pow(v, 0.3));
	float r = mix(vac, air, pressure);
	// Slight breathing of the tail.
	r *= 1.0 + 0.05 * v * sin(TIME * 23.0 + v * 9.0);
	VERTEX.xz *= r / lin;
	v_len = v;
}

void fragment() {
	float v = v_len;
	float u = UV.x;
	float t = TIME;
	// Facing term: ~1 through the middle of the plume, 0 at its silhouette
	// (the cone wall seen edge-on). Used as "how much plume is in this ray".
	float ndv = clamp(abs(dot(NORMAL, VIEW)), 0.0, 1.0);
	float thick = pow(ndv, 1.3);
	// Turbulence: two noise layers scrolling downstream (integer repeats in u
	// keep the seam closed).
	float n1 = texture(noise_tex, vec2(u * 2.0, v * 1.1 - t * 2.6)).r;
	float n2 = texture(noise_tex, vec2(u * 5.0 + 0.37, v * 2.7 - t * 6.3)).r;
	float turb = n1 * 0.62 + n2 * 0.38;

	// Hot core just below the nozzle.
	float core = exp(-v * mix(14.0, 9.0, pressure)) * pow(ndv, 3.0);
	// Shock diamonds (air only): bright nodes along the core.
	float dia = pressure * pow(0.5 + 0.5 * cos(v * 46.0), 3.0) * exp(-v * 6.0) * pow(ndv, 4.0);
	// Luminous body; downstream the turbulence eats it from the edges.
	float ragged = smoothstep(0.2, 0.7, turb + 0.55 - v * 0.8 - (1.0 - ndv) * 0.6);
	float body_air = exp(-v * 1.7) * smoothstep(0.0, 0.04, v) * ragged * (0.75 + 0.5 * turb);
	float body_vac = exp(-v * 5.0) * (0.6 + 0.4 * turb);
	float body = mix(body_vac * 0.35, body_air, pressure) * thick * (1.0 - smoothstep(0.6, 1.0, v));

	vec3 white = vec3(1.0, 0.96, 0.88);
	vec3 yellow = vec3(1.0, 0.72, 0.3);
	vec3 orange = vec3(1.0, 0.42, 0.1);
	vec3 red = vec3(0.7, 0.22, 0.08);
	vec3 air_col = mix(mix(yellow, orange, smoothstep(0.02, 0.25, v)), red, smoothstep(0.35, 0.9, v));
	vec3 vac_col = mix(vec3(1.0, 0.85, 0.7), vec3(0.55, 0.62, 0.95), smoothstep(0.0, 0.4, v));
	vec3 body_col = mix(vac_col, air_col, pressure);

	float flick = 0.9 + 0.1 * sin(t * 47.0 + v * 13.0);
	vec3 c = white * (core * 1.6 + dia * 1.2) + body_col * body * mix(0.9, 0.34, pressure);
	ALBEDO = c * flick * clamp(throttle, 0.0, 1.0);
}
