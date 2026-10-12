shader_type spatial;
// Scorch mark left on the ground by an engine at landing / liftoff: a dark,
// irregular blotch with radial streaks, fading at the edge.
render_mode blend_mix, depth_draw_never, cull_disabled, shadows_disabled;

uniform float seed = 0.0;
uniform float strength = 0.8;

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7)) + seed) * 43758.5453); }
float noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1, 0)), f.x), mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), f.x), f.y);
}

void fragment() {
	vec2 p = (UV - 0.5) * 2.0;
	float r = length(p);
	float ang = atan(p.y, p.x);
	float edge = noise(vec2(ang * 3.0, seed)) * 0.25 + noise(p * 6.0) * 0.15;
	float core = 1.0 - smoothstep(0.15, 0.95, r + edge - 0.1);
	float rays = 0.5 + 0.5 * noise(vec2(ang * 9.0, r * 1.5 + seed));
	float d = core * mix(0.65, 1.0, rays) * (0.75 + 0.25 * noise(p * 17.0));
	ALBEDO = vec3(0.05, 0.043, 0.036);
	ROUGHNESS = 1.0;
	ALPHA = clamp(d * strength, 0.0, 0.9);
}
