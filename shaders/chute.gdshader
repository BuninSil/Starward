shader_type spatial;
// Parachute canopy fabric: gores in vertex colour, cloth bulging between the
// suspension lines, slow "breathing" while inflated, wrinkles while it collapses
// on the ground, light shining through the thin nylon.
render_mode cull_disabled;

uniform float gores = 12.0;
uniform float collapse = 0.0;   // 0 inflated .. 1 lying on the ground
uniform float radius = 7.5;
uniform vec3 ground_up = vec3(0.0, 1.0, 0.0);   // world: local vertical (lying canopy faces it)

void vertex() {
	// atan(0, 0) is NaN on mobile GPUs: the apex vertex would vanish (a hole).
	float ang = atan(VERTEX.z, VERTEX.x + 1e-5);
	float r = length(VERTEX.xz) / radius;          // 0 apex .. 1 skirt
	float between = 0.5 - 0.5 * cos(ang * gores);  // 0 at a line, 1 mid-gore
	float t = TIME;
	float live = 1.0 - collapse;
	// Fabric puffs out between the lines, more towards the skirt.
	float puff = 1.0 + 0.05 * between * r * live;
	// Breathing: the skirt opens and closes a little, slowly.
	puff *= 1.0 + live * r * (0.025 * sin(t * 1.6) + 0.012 * sin(t * 3.7 + ang * 2.0));
	VERTEX.xz *= puff;
	VERTEX.y += live * r * 0.25 * sin(t * 1.6 + 0.6);
	// Collapsed: crumples (the node squashes local Z, which then points up).
	float w = sin(ang * 7.0 + r * 9.0) * sin(r * 13.0 - ang * 3.0) + 0.5 * sin(ang * 17.0 + r * 21.0);
	// Grows as it settles, so the falling canopy stays smooth.
	VERTEX.z += collapse * collapse * w * 2.2 * (0.3 + r);
	VERTEX.y *= 1.0 - 0.25 * collapse * between;
}

void fragment() {
	// A canopy lying on the ground faces up. The squashed geometry's own normals
	// are unreliable on some mobile GPUs (they came out black), so they are
	// eased toward the local vertical as it settles; NaN guarded as well.
	vec3 up_v = normalize((VIEW_MATRIX * vec4(ground_up, 0.0)).xyz);
	vec3 n = NORMAL;
	if (any(isnan(n)) || dot(n, n) < 1e-6) {
		n = up_v;
	}
	n = normalize(mix(n, up_v, smoothstep(0.4, 0.9, collapse) * 0.85));
	NORMAL = n;
	// Inside of the canopy: thin nylon glows with the light coming through it,
	// so light it like the outside (sun side) instead of a black hollow.
	ALBEDO = FRONT_FACING ? COLOR.rgb : COLOR.rgb * 0.8;
	ROUGHNESS = 0.82;
	SPECULAR = 0.25;
}

// Own lighting: the engine's GGX highlight overflows in half precision on some
// mobile GPUs right where the sun glints off the fabric (a black disc there).
// Lambert, light through the thin nylon from behind, and a soft clamped sheen.
void light() {
	float ndl = dot(NORMAL, LIGHT);
	vec3 lc = LIGHT_COLOR * ATTENUATION / PI;
	// Light through the nylon is tinted by the nylon itself (as BACKLIGHT did).
	DIFFUSE_LIGHT += lc * (1.08 * max(ndl, 0.0) + 0.45 * ALBEDO * (1.0 - max(ndl, 0.0)));
	vec3 h = normalize(LIGHT + VIEW);
	float nh = clamp(dot(NORMAL, h), 0.0, 1.0);
	float n2 = nh * nh;
	float n4 = n2 * n2;
	float n8 = n4 * n4;
	SPECULAR_LIGHT += lc * max(ndl, 0.0) * 0.03 * n8 * n8;   // nh^16, all values <= 1
}
