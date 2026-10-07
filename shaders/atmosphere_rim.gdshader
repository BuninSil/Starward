shader_type spatial;
// Simplified atmosphere for weak devices: additive fresnel rim lit by the sun.
render_mode unshaded, blend_add, cull_back, depth_draw_never, shadows_disabled;

uniform vec3 glow_color : source_color = vec3(0.35, 0.6, 1.0);
uniform float power = 3.5;
uniform float intensity = 1.4;
uniform vec3 sun_dir_world = vec3(1.0, 0.3, 0.4);

varying vec3 world_normal;

void vertex() {
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	float rim = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), power);
	float lit = clamp(dot(world_normal, normalize(sun_dir_world)) * 0.8 + 0.35, 0.0, 1.0);
	ALBEDO = glow_color * rim * lit * intensity;
}
