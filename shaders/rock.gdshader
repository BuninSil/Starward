shader_type spatial;
// Surface boulders (planet_view.gd _rock_meshes): stone colour with a cracked
// pattern projected along the dominant facet axis (one texture read; facets are
// flat), dust settled on the upward faces, per-instance tint from the MultiMesh.
// Also used for pebbles (fading out with distance) and Martian dust drifts.

uniform vec3 rock_color = vec3(0.07);   // linear
uniform vec3 dust_color = vec3(0.12);   // linear
uniform sampler2D ground_pack : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform float fade_end = 0.0;   // > 0: instances shrink away beyond this camera distance (pebbles)

varying vec3 obj_pos;
varying vec3 obj_n;

void vertex() {
	obj_pos = VERTEX;
	obj_n = NORMAL;
	if (fade_end > 0.0) {
		vec3 origin = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
		float d = distance(origin, (INV_VIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz);
		VERTEX *= 1.0 - smoothstep(fade_end * 0.6, fade_end, d);
	}
}

void fragment() {
	vec3 a = abs(obj_n);
	vec2 uv = a.y > a.x && a.y > a.z ? obj_pos.xz : (a.x > a.z ? obj_pos.zy : obj_pos.xy);
	vec4 p = texture(ground_pack, uv * 0.45 + obj_n.xz * 0.37);
	// Cracks darken, grains add speckle.
	float pattern = (0.62 + 0.55 * p.g) * (0.85 + 0.3 * p.r);
	vec3 stone = rock_color * pattern * COLOR.rgb;
	float dust = smoothstep(0.45, 0.85, obj_n.y) * (0.55 + 0.45 * p.b);
	ALBEDO = mix(stone, dust_color * (0.9 + 0.2 * p.r), dust);
	ROUGHNESS = 0.92;
	SPECULAR = 0.3;
}
