shader_type spatial;
// Rocket part skin (rocket_view.gd), clean "SFS-like" painted look.
// UV = (angle 0..1 around, height in metres from the part bottom).
//  * base paint + up to two accent bands (height ranges) + optional checker;
//  * crisp panel seams (rings / stringers) and rounded window cut-outs painted
//    as glossy dark glass with a frame (no extra geometry: no z-fighting);
//  * hatch outline / dark opening when the door is swung away;
//  * metal / foil with a fake environment reflection (env_* globals set by
//    flight.gd: sky above, lit ground below) so metal is not black without
//    real reflections on mobile; engine bell heat glow.

uniform vec3 base_color = vec3(0.8);    // linear
uniform vec3 band_color = vec3(0.6, 0.15, 0.02);
uniform vec4 band1 = vec4(0.0);         // y0, y1 (metres), on (z > 0)
uniform vec4 band2 = vec4(0.0);
uniform vec3 alt_color = vec3(0.02);
uniform int pattern = 0;                // 0 none, 1 roll checker on [band1]
uniform float panel_h = 0.0;            // ring seams spacing, metres (0 none)
uniform float stringers = 0.0;          // vertical seams around (0 none)
uniform float corrugation = 0.0;        // ribs around
uniform float rough = 0.45;
uniform float metal = 0.0;
uniform float foil = 0.0;
uniform float gloss = 0.2;              // paint clear-coat reflection
// Windows: count around (0 none), centre height, size (u fraction, metres),
// first window centre angle (u).
uniform float win_count = 0.0;
uniform float win_v = 1.0;
uniform vec2 win_size = vec2(0.06, 0.3);
uniform float win_u0 = 0.0;
uniform float win_n = 99.0;             // only the first N windows from win_u0
// Hatch: centre (u, v), size (u fraction, metres), open amount.
uniform vec4 hatch = vec4(0.0);         // u, v, du, dv (du = 0: none)
uniform float hatch_open = 0.0;
uniform float soot = 0.0;
uniform float heat = 0.0;
uniform float heat_v0 = 0.0;
uniform sampler2D noise_tex : hint_default_white, filter_linear_mipmap, repeat_enable;
global uniform vec3 env_sky;
global uniform vec3 env_ground;
global uniform vec3 env_up;

float seam(float x, float w) {
	float d = abs(fract(x) - 0.5);
	return 1.0 - smoothstep(0.5 - w, 0.5, d);
}

// Rounded-rectangle mask: 1 inside, soft edge; p in units of the half size.
float rrect(vec2 p, float r) {
	vec2 q = abs(p) - (1.0 - r);
	float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
	return 1.0 - smoothstep(-0.04, 0.04, d);
}

void fragment() {
	float u = UV.x;
	float v = UV.y;
	vec3 col = base_color;
	if (band1.z > 0.0 && v > band1.x && v < band1.y) {
		col = band_color;
		if (pattern == 1 && mod(floor(u * 4.0), 2.0) < 0.5) col = alt_color;
	}
	if (band2.z > 0.0 && v > band2.x && v < band2.y) col = band_color;
	float rgh = rough;
	float m = max(metal, foil);
	vec2 bump = vec2(0.0);
	// Panel seams: thin dark grooves.
	float sm = 0.0;
	if (panel_h > 0.0) sm = max(sm, seam(v / panel_h + 0.5, fwidth(v / panel_h) * 1.2 + 0.002));
	if (stringers > 0.0) sm = max(sm, seam(u * stringers + 0.5, fwidth(u * stringers) * 1.2 + 0.002) * 0.7);
	col *= 1.0 - 0.22 * sm;
	if (corrugation > 0.0) {
		float s = sin(u * 6.2832 * corrugation);
		col *= 0.88 + 0.12 * s;
		bump.x += cos(u * 6.2832 * corrugation) * 0.5;
	}
	if (foil > 0.0) {
		vec4 n = texture(noise_tex, vec2(u * 7.0, v * 1.1));
		vec4 n2 = texture(noise_tex, vec2(u * 19.0, v * 2.9) + 0.37);
		col *= 0.85 + 0.3 * n.r * n2.g;
		bump += (vec2(n.g, n2.r) - 0.5) * 1.6;
	}
	// Windows: glossy dark glass in a light frame.
	float glass = 0.0;
	if (win_count > 0.0) {
		float cu = (u - win_u0) * win_count;
		float idx = mod(floor(cu + 0.5), win_count);
		vec2 p = vec2((fract(cu + 0.5) - 0.5) / (win_size.x * win_count), (v - win_v) / win_size.y) * 2.0;
		float on = step(idx, win_n - 0.5);
		float frame = rrect(p * 0.84, 0.45) * on;
		glass = rrect(p, 0.45) * on;
		col = mix(col, vec3(0.55), frame * (1.0 - glass));
	}
	// Hatch: outline groove, dark opening when the door is away.
	if (hatch.z > 0.0) {
		float du = u - hatch.x;
		vec2 p = vec2(du / hatch.z, (v - hatch.y) / hatch.w) * 2.0;
		float inside = rrect(p, 0.3);
		float ring = rrect(p * 0.97, 0.3) - rrect(p * 1.06, 0.3);
		col *= 1.0 - 0.5 * clamp(ring, 0.0, 1.0);
		col = mix(col, vec3(0.008), inside * hatch_open);
	}
	float st = soot * exp(-v / 1.4);
	col = mix(col, vec3(0.03, 0.028, 0.026), clamp(st, 0.0, 0.85));
	// Reflection of the fake environment.
	vec3 nv = normalize(NORMAL + (TANGENT * bump.x + BINORMAL * bump.y) * 0.3);
	vec3 rw = (INV_VIEW_MATRIX * vec4(reflect(-VIEW, nv), 0.0)).xyz;
	float h = dot(rw, env_up);
	vec3 env = mix(env_ground, env_sky, smoothstep(-0.12, 0.2, h)) + env_sky * 0.3 * exp(-abs(h) * 9.0);
	env = max(env, vec3(0.025));   // a little studio fill so metal never reads as a hole
	float fres = pow(1.0 - clamp(dot(nv, VIEW), 0.0, 1.0), 5.0);
	float g = mix(gloss, 1.0, m);
	vec3 f0 = mix(vec3(0.04), col, m);
	if (glass > 0.0) {
		col = mix(col, vec3(0.01, 0.012, 0.018), glass);
		f0 = mix(f0, vec3(0.06), glass);
		g = mix(g, 1.0, glass);
		rgh = mix(rgh, 0.08, glass);
	}
	ALBEDO = col;
	METALLIC = m * (1.0 - glass);
	ROUGHNESS = foil > 0.0 ? 0.25 : rgh;
	SPECULAR = 0.5;
	EMISSION = env * mix(f0, vec3(1.0), fres) * g;
	NORMAL_MAP = normalize(vec3(bump * 0.5, 1.0)) * 0.5 + 0.5;
	NORMAL_MAP_DEPTH = 1.0;
	if (heat > 0.0) {
		EMISSION += vec3(1.0, 0.35, 0.08) * exp(-abs(v - heat_v0) / 0.3) * heat * 2.0;
	}
}
