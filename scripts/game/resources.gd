class_name Resources
extends RefCounted
## What the ground holds, per body and place: richness 0..1 of ice, ore and
## regolith. Deterministic (noise seeded by the body), so a deposit stays where
## it was found. Ice gathers near the poles (cold traps), ore in patches,
## regolith almost everywhere on airless bodies.

const KINDS := ["ice", "ore", "regolith"]

static var _noise := {}


static func _n(body_id: String, salt: int, dir: Vector3, freq: float) -> float:
	var key := "%s/%d" % [body_id, salt]
	var fn: FastNoiseLite = _noise.get(key)
	if fn == null:
		fn = FastNoiseLite.new()
		fn.seed = hash(key)
		fn.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
		fn.fractal_octaves = 3
		_noise[key] = fn
	fn.frequency = freq
	var p := dir * 100.0
	return clampf(fn.get_noise_3d(p.x, p.y, p.z) * 0.5 + 0.5, 0.0, 1.0)


## Richness of each resource at lat/lon (degrees) on a body: {id: 0..1}.
static func at(body_id: String, lat: float, lon: float) -> Dictionary:
	var la := deg_to_rad(lat)
	var lo := deg_to_rad(lon)
	var dir := Vector3(cos(la) * cos(lo), sin(la), cos(la) * sin(lo))
	var patch := _n(body_id, 1, dir, 0.08)        # ore deposits, ~km scale
	var wet := _n(body_id, 2, dir, 0.05)          # where ice sits in cold traps
	var pole := absf(lat)
	var r := {"ice": 0.0, "ore": 0.0, "regolith": 0.0}
	match body_id:
		"moon", "mercury":
			r.regolith = 0.85
			r.ore = 0.1 + 0.6 * smoothstep(0.45, 0.85, patch)
			r.ice = smoothstep(70.0, 85.0, pole) * (0.5 + 0.5 * wet)
		"mars":
			r.regolith = 0.75
			r.ore = 0.15 + 0.6 * smoothstep(0.45, 0.85, patch)
			r.ice = smoothstep(40.0, 70.0, pole) * 0.9 + 0.12 * smoothstep(0.6, 0.9, wet)
		"phobos", "deimos":
			r.regolith = 0.9
			r.ore = 0.2 + 0.5 * smoothstep(0.4, 0.85, patch)
			r.ice = 0.05 * wet
		"venus":
			r.regolith = 0.5
			r.ore = 0.3 + 0.6 * smoothstep(0.4, 0.8, patch)
		"earth":
			r.regolith = 0.4
			r.ore = 0.1 + 0.5 * smoothstep(0.5, 0.9, patch)
			r.ice = smoothstep(60.0, 75.0, pole)
	for k in r:
		r[k] = clampf(r[k], 0.0, 1.0)
	return r


static func describe(r: Dictionary) -> String:
	var parts := PackedStringArray()
	for k in KINDS:
		parts.append("%s %d%%" % [Items.name_of(k), int(round(float(r.get(k, 0.0)) * 100.0))])
	return " · ".join(parts)


## One drill pull: picks a resource weighted by richness, or "" if bare rock.
static func pick(r: Dictionary, rng: RandomNumberGenerator) -> String:
	var total := 0.0
	for k in KINDS:
		total += float(r.get(k, 0.0))
	if total < 0.05:
		return ""
	var x := rng.randf() * total
	for k in KINDS:
		x -= float(r.get(k, 0.0))
		if x <= 0.0:
			return k
	return KINDS[KINDS.size() - 1]
