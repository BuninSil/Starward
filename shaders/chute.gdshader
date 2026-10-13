shader_type spatial;
// Parachute canopy fabric: gores in vertex colour, cloth bulging between the
// suspension lines, slow "breathing" while inflated, wrinkles while it collapses
// on the ground, light shining through the thin nylon.
render_mode cull_disabled;

uniform float gores = 12.0;
uniform float collapse = 0.0;   // 0 inflated .. 1 lying on the ground
uniform float radius = 7.5;

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
	// Inside of the canopy: thin nylon glows with the light coming through it,
	// so light it like the outside (sun side) instead of a black hollow.
	ALBEDO = FRONT_FACING ? COLOR.rgb : COLOR.rgb * 0.8;
	ROUGHNESS = 0.82;
	SPECULAR = 0.25;
	// Thin nylon: sunlight shows through from behind.
	BACKLIGHT = COLOR.rgb * 0.45;
}
