shader_type sky;
// Cheap procedural starfield: hashed cells on the view direction.
// Runs once per sky update (radiance), the background pass is a single
// fullscreen draw — fine for mobile.

uniform vec3 space_color : source_color = vec3(0.004, 0.006, 0.014);
uniform float density : hint_range(0.0, 1.0) = 0.06;
uniform float scale = 220.0;

float hash13(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.zyx + 31.32);
	return fract((p.x + p.y) * p.z);
}

float star_layer(vec3 dir, float s) {
	vec3 cell = floor(dir * s);
	float h = hash13(cell);
	if (h > density) {
		return 0.0;
	}
	vec3 center = (cell + 0.5 + (vec3(hash13(cell + 1.7), hash13(cell + 5.3), hash13(cell + 9.1)) - 0.5) * 0.6) / s;
	float d = length(dir - center) * s;
	float b = hash13(cell + 3.3);
	return smoothstep(0.35, 0.0, d) * (0.25 + 0.75 * b * b);
}

void sky() {
	vec3 dir = normalize(EYEDIR);
	float stars = star_layer(dir, scale) + 0.6 * star_layer(dir, scale * 2.3);
	// faint milky band
	float band = exp(-pow(dir.y * 3.0 + dir.x * 0.8, 2.0)) * 0.025;
	vec3 tint = mix(vec3(0.75, 0.82, 1.0), vec3(1.0, 0.9, 0.75), hash13(floor(dir * scale)));
	COLOR = space_color + vec3(band * 0.6, band * 0.7, band) + stars * tint;
}
