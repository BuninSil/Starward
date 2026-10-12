shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled;
// Rocket exhaust plume on a cone (rocket_view.gd): UV.y = 0 at the nozzle,
// 1 at the tail. Hot white core, orange body, flicker; in air shock diamonds
// and a tighter plume, in vacuum a wide faint bluish one.

uniform float throttle = 1.0;
uniform float pressure = 1.0;   // 0 vacuum .. 1 sea level

void fragment() {
	float v = UV.y;
	float u = UV.x;
	float t = TIME;
	float flick = 0.85 + 0.15 * sin(t * 43.0 + u * 31.0) * sin(t * 27.0 + v * 9.0);
	// Rim fade: the cone wall seen edge-on is the plume's outer layer.
	float rim = pow(clamp(abs(dot(NORMAL, VIEW)), 0.0, 1.0), 1.5);
	float core = exp(-v * 7.0);
	float body = (1.0 - smoothstep(0.15, 1.0, v));
	float diamonds = pressure * (0.5 + 0.5 * cos(v * 38.0)) * exp(-v * 2.5);
	vec3 hot = vec3(1.0, 0.95, 0.85);
	vec3 air_col = vec3(1.0, 0.55, 0.18);
	vec3 vac_col = vec3(0.55, 0.65, 1.0);
	vec3 col = mix(vac_col * 0.6, air_col, pressure);
	vec3 c = hot * core * 2.2 + col * body * (0.8 + 0.6 * diamonds) + hot * diamonds * 0.6;
	float a = (core * 1.2 + body * mix(0.25, 0.7, pressure)) * rim * flick * clamp(throttle, 0.0, 1.0);
	ALBEDO = c * a;
}
