shader_type spatial;
// Launch pad concrete (launch_pad.gd): slab joints, stains, scorch around the
// flame trench, painted markings. Object-space xz in metres.

uniform sampler2D noise_tex : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform float radius = 30.0;
varying vec3 p;

void vertex() {
	p = VERTEX;
}

float line(float x, float w) {
	float d = abs(fract(x) - 0.5);
	return 1.0 - smoothstep(0.5 - w, 0.5, d);
}

void fragment() {
	vec2 xz = p.xz;
	float r = length(xz);
	vec4 n = texture(noise_tex, xz / 23.0);
	vec4 n2 = texture(noise_tex, xz / 5.0 + 0.3);
	vec3 col = vec3(0.66, 0.63, 0.58) * (0.85 + 0.25 * n.r) * (0.94 + 0.12 * n2.g);
	// Slab joints every 4 m.
	float j = max(line(xz.x / 4.0 + 0.5, 0.02), line(xz.y / 4.0 + 0.5, 0.02));
	col *= 1.0 - 0.35 * j;
	// Scorch and soot from launches, streaky along the trench (x axis).
	float sc = exp(-r / 6.0) + 0.6 * exp(-abs(xz.y) / 2.5) * exp(-abs(xz.x) / 14.0);
	col *= 1.0 - clamp(sc * (0.6 + 0.5 * n2.r), 0.0, 0.85);
	// Painted circle and hazard stripes along the trench edges.
	float ring = 1.0 - smoothstep(0.12, 0.2, abs(r - 9.0));
	vec3 yellow = vec3(0.85, 0.65, 0.08) * (0.8 + 0.2 * n2.b);
	col = mix(col, yellow, ring * 0.8 * (1.0 - clamp(sc, 0.0, 1.0)));
	float edge = (1.0 - smoothstep(0.3, 0.35, abs(abs(xz.y) - 3.0))) * step(abs(xz.x), 16.0) * step(4.0, abs(xz.x));
	float stripes = step(0.5, fract((xz.x + xz.y) / 1.2));
	col = mix(col, mix(vec3(0.03), yellow, stripes), edge * 0.85);
	// Outer kerb.
	col *= 1.0 - 0.3 * (1.0 - smoothstep(0.0, 0.6, radius - r));
	ALBEDO = col;
	ROUGHNESS = 0.92;
	SPECULAR = 0.2;
}
