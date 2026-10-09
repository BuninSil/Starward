#!/usr/bin/env python3
"""Download public-domain NASA planet maps and convert them for the game.

Outputs (all equirectangular, north at the top, longitude -180..180 left to right):
  <body>_color.jpg   colour texture
  <body>_height.bin  int16 little-endian, metres at REAL scale (game divides by 10)
  <body>_normal.png  tangent-space normal map (OpenGL / Godot convention, green = north)
  <body>.json        sizes, units, sources

Run by .github/workflows/fetch-planet-maps.yml (the dev machine has no access to NASA).
"""
import argparse
import json
import math
import os
import sys
import urllib.request

import numpy as np
from PIL import Image

Image.MAX_IMAGE_PIXELS = None

# Blue Marble Next Generation, July 2004 (summer in the north: green land, little snow).
# Record ids are not stable knowledge, so try known ones and fall back to scraping
# Visible Earth for the July file names.
EARTH_COLOR = [
    "https://eoimages.gsfc.nasa.gov/images/imagerecords/76000/76487/world.200407.3x5400x2700.jpg",
    "https://eoimages.gsfc.nasa.gov/images/imagerecords/74000/74368/world.200407.3x5400x2700.jpg",
    "https://eoimages.gsfc.nasa.gov/images/imagerecords/73000/73751/world.topo.bathy.200407.3x5400x2700.jpg",
    "https://eoimages.gsfc.nasa.gov/images/imagerecords/74000/74393/world.topo.200407.3x5400x2700.jpg",
]
EARTH_COLOR_FILES = [r"world\.200407\.3x5400x2700\.jpg", r"world\.topo\.bathy\.200407\.3x5400x2700\.jpg",
                     r"world\.topo\.200407\.3x5400x2700\.jpg"]
VISIBLE_EARTH_PAGES = [
    "https://visibleearth.nasa.gov/collection/1484/blue-marble",
    "https://visibleearth.nasa.gov/collection/1484/blue-marble?page=2",
    "https://visibleearth.nasa.gov/collection/1484/blue-marble?page=3",
    "https://visibleearth.nasa.gov/collection/1484/blue-marble?page=4",
]
EARTH_ELEV = [
    "https://eoimages.gsfc.nasa.gov/images/imagerecords/73000/73934/gebco_08_rev_elev_21600x10800.png",
]
EARTH_BATH = [
    "https://eoimages.gsfc.nasa.gov/images/imagerecords/73000/73963/gebco_08_rev_bath_21600x10800.png",
]
MOON_COLOR = [
    "https://svs.gsfc.nasa.gov/vis/a000000/a004700/a004720/lroc_color_poles_4k.tif",
    "https://svs.gsfc.nasa.gov/vis/a000000/a004700/a004720/lroc_color_poles_2k.tif",
]
MOON_DEM = [
    "https://svs.gsfc.nasa.gov/vis/a000000/a004700/a004720/ldem_16.tif",
    "https://svs.gsfc.nasa.gov/vis/a000000/a004700/a004720/ldem_4.tif",
]

USGS = "https://planetarymaps.usgs.gov/mosaic/"
MARS_COLOR = [
    "https://astrogeology.usgs.gov/ckan/dataset/7131d503-cdc9-45a5-8f83-5126c0fd397e/resource/5ea881c6-01b3-41fa-a7af-42d2131b54f1/download/mars_viking_mdim21_clrmosaic_1km.jpg",
    USGS + "Mars_Viking_ClrMosaic_global_925m.tif",
]
MARS_DEM = [
    "https://pds-geosciences.wustl.edu/mgs/urn-nasa-pds-mgs_mola_topography_derived/meg004/megt90n000cb.img",
    "https://pds-geosciences.wustl.edu/mgs/mgs-m-mola-5-megdr-l3-v1/mgsl_300x/meg004/megt90n000cb.img",
]
MERCURY_COLOR = [USGS + "Mercury_MESSENGER_ClrMosaic_global_665m_v3.tif"]
MERCURY_DEM = [USGS + "Mercury_Messenger_USGS_DEM_Global_665m_v2.tif"]
VENUS_RADAR = [USGS + "Venus_Magellan_C3-MDIR_Global_Mosaic_2025m.tif"]
VENUS_DEM = [USGS + "Venus_Magellan_Topography_Global_4641m_v02.tif", USGS + "Venus_Magellan_Topography_Global_4641m.tif"]
PHOBOS_COLOR = [USGS + "Phobos_Viking_Mosaic_40ppd_DLRcontrol.tif"]
PHOBOS_DEM = [USGS + "Phobos_ME_HRSC_DEM_Global_2ppd.tif"]

PROBES = {
    "earth": {"Everest": (27.99, 86.93), "Mariana": (11.35, 142.2), "Baikonur": (45.97, 63.3),
              "Amazon": (-3.0, -60.0), "MidAtlantic": (0.0, -25.0), "Tibet": (32.0, 90.0),
              "DeadSea": (31.5, 35.5), "Greenland": (72.0, -40.0)},
    "mars": {"OlympusMons": (18.65, -133.8), "Hellas": (-42.4, 70.5), "VallesMarineris": (-8.0, -75.0),
             "NorthPole": (88.0, 0.0)},
    "mercury": {"Caloris": (30.5, 162.7), "Equator0": (0.0, 0.0)},
    "venus": {"MaxwellMontes": (65.2, 3.3), "AphroditeTerra": (-5.0, 105.0)},
    "phobos": {"Stickney": (1.0, -49.0), "Equator0": (0.0, 0.0)},
    "moon": {"Tycho": (-43.3, -11.2), "Imbrium": (32.8, -15.6), "Tranquillitatis": (8.5, 31.4),
             "FarHighland": (5.0, -158.0), "SPA_basin": (-53.0, -169.0)},
}


def fetch(urls, work):
    for u in urls:
        name = os.path.join(work, os.path.basename(u))
        if os.path.exists(name) and os.path.getsize(name) > 0:
            return name
        try:
            print("download", u, flush=True)
            req = urllib.request.Request(u, headers={"User-Agent": "Starward-map-fetch"})
            with urllib.request.urlopen(req, timeout=600) as r, open(name, "wb") as f:
                while True:
                    chunk = r.read(1 << 20)
                    if not chunk:
                        break
                    f.write(chunk)
            print("  ok", os.path.getsize(name) // 1024, "KiB", flush=True)
            return name
        except Exception as e:  # try the next mirror
            print("  failed:", e, flush=True)
    raise SystemExit("all sources failed: %s" % urls)


def _get_text(u):
    req = urllib.request.Request(u, headers={"User-Agent": "Starward-map-fetch"})
    with urllib.request.urlopen(req, timeout=120) as r:
        return r.read().decode("utf-8", "replace")


def scrape_july_urls():
    """Finds July Blue Marble image URLs on Visible Earth (best effort)."""
    import re
    found = []
    pages = []
    for p in VISIBLE_EARTH_PAGES:
        try:
            html = _get_text(p)
        except Exception as e:
            print("  scrape failed", p, e, flush=True)
            continue
        for m in re.finditer(r'href="(/images/\d+/july[^"]*)"', html):
            pages.append("https://visibleearth.nasa.gov" + m.group(1))
    for p in dict.fromkeys(pages):
        try:
            html = _get_text(p)
        except Exception as e:
            print("  scrape failed", p, e, flush=True)
            continue
        for pat in EARTH_COLOR_FILES:
            for m in re.finditer(r'(https://[^"\s]*' + pat + ')', html):
                found.append(m.group(1))
    print("  scraped July candidates:", found, flush=True)
    # Plain colour first (no baked relief shading), then the others.
    found.sort(key=lambda u: [i for i, pat in enumerate(EARTH_COLOR_FILES) if __import__("re").search(pat, u)][0])
    return list(dict.fromkeys(found))


def load_array(path):
    if path.lower().endswith((".tif", ".tiff")):
        import tifffile
        a = tifffile.imread(path)
    else:
        a = np.asarray(Image.open(path))
    print("  loaded", os.path.basename(path), a.shape, a.dtype, "min", a.min(), "max", a.max(), flush=True)
    return a


def load_geotiff(path, max_width=8192):
    """Large GeoTIFF -> (array decimated to <= max_width columns, lon of the left edge
    is -180). Planetary mosaics come either -180..180 or 0..360; the latter is rolled."""
    import tifffile
    with tifffile.TiffFile(path) as tf:
        page = tf.pages[0]
        tie = page.tags.get("ModelTiepointTag")
        scale = page.tags.get("ModelPixelScaleTag")
        a = page.asarray(out="memmap") if page.is_memmappable else page.asarray()
        h, w = a.shape[:2]
        step = max(1, w // max_width)
        a = np.array(a[::step, ::step])
        print("  tif", os.path.basename(path), (h, w), "->", a.shape, a.dtype,
              "tie", tie.value if tie else None, "scale", scale.value if scale else None, flush=True)
        if tie is not None and scale is not None:
            x0 = tie.value[3]
            if x0 > -1.0:   # starts at 0 E: roll so the left edge is 180 W
                a = np.roll(a, a.shape[1] // 2, axis=1)
                print("  rolled 0..360 -> -180..180", flush=True)
    return a


def clean_nodata(h):
    h = h.astype(np.float32)
    bad = (h < -20000) | (h > 30000) | ~np.isfinite(h)
    if bad.any():
        h[bad] = np.median(h[~bad])
        print("  nodata filled:", int(bad.sum()), flush=True)
    return h


def fill_gaps(img, valid):
    """Fills invalid pixels of a float image (H, W[, C]) with a blurred average of
    the valid ones around them (normalized convolution, several radii)."""
    from PIL import ImageFilter
    out = img.copy()
    m = valid.astype(np.float32)
    chans = [img] if img.ndim == 2 else [img[..., k] for k in range(img.shape[2])]
    filled = []
    for ch in chans:
        res = ch.copy()
        todo = ~valid
        for radius in (4, 16, 64, 256):
            if not todo.any():
                break
            num = np.asarray(Image.fromarray((ch * m).astype(np.float32), mode="F").filter(ImageFilter.BoxBlur(radius)))
            den = np.asarray(Image.fromarray(m, mode="F").filter(ImageFilter.BoxBlur(radius)))
            ok = todo & (den > 0.05)
            res[ok] = num[ok] / den[ok]
            todo = todo & ~ok
        if todo.any():
            res[todo] = np.median(ch[valid])
        filled.append(res)
    out = filled[0] if img.ndim == 2 else np.stack(filled, axis=-1)
    print("  gaps filled:", int((~valid).sum()), flush=True)
    return out


def calm_poles(img, start_deg=72.0):
    """Equirectangular maps smear into radial streaks at the poles: blend rows near
    the poles toward their mean colour."""
    h = img.shape[0]
    lat = 90.0 - (np.arange(h) + 0.5) / h * 180.0
    w = np.clip((np.abs(lat) - start_deg) / (89.0 - start_deg), 0.0, 1.0)
    w = w * w * (3.0 - 2.0 * w)
    mean = img.mean(axis=1, keepdims=True)
    ww = w[:, None, None] if img.ndim == 3 else w[:, None]
    return img * (1.0 - ww) + mean * ww


def probe(name, arr, points):
    h, w = arr.shape[:2]
    for k, (lat, lon) in points.items():
        x = int((lon + 180.0) / 360.0 * w) % w
        y = min(int((90.0 - lat) / 180.0 * h), h - 1)
        print("  probe %-16s %-14s %s" % (name, k, arr[y, x]), flush=True)


def resize_float(a, w, h):
    return np.asarray(Image.fromarray(a.astype(np.float32), mode="F").resize((w, h), Image.BOX))


def normal_map(height_m_real, radius_game, scale_div, exaggerate):
    """Tangent-space normals from real-scale heights on a sphere of game radius."""
    h = height_m_real.astype(np.float64) / scale_div
    rows, cols = h.shape
    lat = (0.5 - (np.arange(rows) + 0.5) / rows) * math.pi
    dx = (2.0 * math.pi * radius_game / cols) * np.maximum(np.cos(lat), 0.05)[:, None]
    dy = math.pi * radius_game / rows
    dhdx = (np.roll(h, -1, axis=1) - np.roll(h, 1, axis=1)) / (2.0 * dx)
    north = np.vstack([h[:1], h[:-1]])
    south = np.vstack([h[1:], h[-1:]])
    dhdy_north = (north - south) / (2.0 * dy)
    nx = -dhdx * exaggerate
    ny = -dhdy_north * exaggerate
    nz = np.ones_like(nx)
    inv = 1.0 / np.sqrt(nx * nx + ny * ny + nz * nz)
    rgb = np.stack([nx * inv, ny * inv, nz * inv], axis=-1) * 0.5 + 0.5
    return Image.fromarray((rgb * 255.0 + 0.5).clip(0, 255).astype(np.uint8), mode="RGB")


def write_body(out, name, color_img, height_m, radius_game, exaggerate, sources, size):
    w, h = size
    color_img.convert("RGB").resize((w * 2, h * 2), Image.LANCZOS).save(
        os.path.join(out, name + "_color.jpg"), quality=88, optimize=True)
    hm = resize_float(height_m, w, h)
    np.clip(np.round(hm), -32768, 32767).astype("<i2").tofile(os.path.join(out, name + "_height.bin"))
    normal_map(hm, radius_game, 10.0, exaggerate).save(os.path.join(out, name + "_normal.png"), optimize=True)
    meta = {"width": w, "height": h, "unit_m": 1.0, "scale_div": 10.0, "format": "int16le",
            "rows": "north_to_south", "cols": "lon_-180_to_180",
            "color": name + "_color.jpg", "normal": name + "_normal.png", "sources": sources,
            "min_m": float(hm.min()), "max_m": float(hm.max())}
    with open(os.path.join(out, name + ".json"), "w") as f:
        json.dump(meta, f, indent=1)
    print(name, "written:", meta, flush=True)


def earth(work, out, size):
    try:
        color_path = fetch(EARTH_COLOR, work)
    except SystemExit:
        color_path = fetch(scrape_july_urls(), work)
    print("  earth colour:", os.path.basename(color_path), flush=True)
    color = Image.open(color_path)
    elev = load_array(fetch(EARTH_ELEV, work)).astype(np.float32)
    bath = load_array(fetch(EARTH_BATH, work)).astype(np.float32)
    if elev.ndim == 3:
        elev = elev[..., 0]
    if bath.ndim == 3:
        bath = bath[..., 0]
    probe("elev_px", elev, PROBES["earth"])
    probe("bath_px", bath, PROBES["earth"])
    # Visible Earth GEBCO renders: elevation 0..255 -> 0..6400 m (land, sea = 0),
    # bathymetry 0..255 -> 0..-8000 m with white = sea level (land = white).
    land = elev / 255.0 * 6400.0
    depth = -(255.0 - bath) / 255.0 * 8000.0
    height = np.where(elev > 0.5, land, depth)
    probe("height_m", height, PROBES["earth"])
    write_body(out, "earth", color, height, 637_100.0, 4.0,
               [os.path.basename(color_path), EARTH_ELEV[0], EARTH_BATH[0]], size)
    # Water mask (white = sea) for the gloss / water colour in the planet shader.
    w, h = size
    water = (elev <= 0.5).astype(np.float32)
    wm = resize_float(water, w, h)
    Image.fromarray((wm * 255.0 + 0.5).clip(0, 255).astype(np.uint8), mode="L").save(
        os.path.join(out, "earth_water.png"), optimize=True)
    print("earth water mask written", flush=True)


def moon(work, out, size):
    color = Image.open(fetch(MOON_COLOR, work))
    dem = load_array(fetch(MOON_DEM, work)).astype(np.float32)
    if dem.ndim == 3:
        dem = dem[..., 0]
    # CGI Moon Kit ldem_*: kilometres relative to 1737.4 km.
    height = dem * 1000.0 if np.abs(dem).max() < 50 else dem
    probe("height_m", height, PROBES["moon"])
    write_body(out, "moon", color, height, 173_740.0, 2.0, [MOON_COLOR[0], MOON_DEM[0]], size)


def mars(work, out, size):
    cp = fetch(MARS_COLOR, work)
    color = Image.open(cp) if cp.lower().endswith(".jpg") else Image.fromarray(load_geotiff(cp, 8192)[..., :3])
    print("  mars colour", color.size, flush=True)
    raw = np.fromfile(fetch(MARS_DEM, work), dtype=">i2").reshape(720, 1440).astype(np.float32)
    height = np.roll(raw, 720, axis=1)   # MEGDR columns start at 0 E
    probe("height_m", height, PROBES["mars"])
    write_body(out, "mars", color, height, 338_950.0, 2.0, [os.path.basename(cp), MARS_DEM[0]], size)


def mercury(work, out, size):
    c = load_geotiff(fetch(MERCURY_COLOR, work), 6144)
    if c.ndim == 3:
        # The MESSENGER colour mosaic is enhanced (false) colour: keep its brightness,
        # give it Mercury's real dull grey-brown.
        lum = c[..., :3].astype(np.float32).mean(axis=2)
    else:
        lum = c.astype(np.float32)
    lum = calm_poles(fill_gaps(lum, lum > 2.0), 70.0)
    lum = (lum - np.percentile(lum, 1)) / max(np.percentile(lum, 99) - np.percentile(lum, 1), 1.0)
    lum = np.clip(lum, 0.0, 1.0) * 0.75 + 0.12
    rgb = np.stack([lum * 1.0, lum * 0.95, lum * 0.88], axis=-1)
    color = Image.fromarray((rgb * 255).clip(0, 255).astype(np.uint8), mode="RGB")
    height = clean_nodata(load_geotiff(fetch(MERCURY_DEM, work), 4096))
    height -= np.median(height)
    height = calm_poles(height, 80.0)
    probe("height_m", height, PROBES["mercury"])
    write_body(out, "mercury", color, height, 243_970.0, 2.5, [MERCURY_COLOR[0], MERCURY_DEM[0]], size)


def venus(work, out, size):
    r = load_geotiff(fetch(VENUS_RADAR, work), 8192).astype(np.float32)
    if r.ndim == 3:
        r = r[..., 0]
    r = calm_poles(fill_gaps(r, r > 2.0), 75.0)
    r = np.clip((r - np.percentile(r, 1)) / max(np.percentile(r, 99) - np.percentile(r, 1), 1.0), 0, 1)
    # Radar brightness tinted like the surface under the orange-lit sky.
    rgb = np.stack([0.30 + 0.55 * r, 0.20 + 0.40 * r, 0.10 + 0.22 * r], axis=-1)
    color = Image.fromarray((rgb * 255).clip(0, 255).astype(np.uint8), mode="RGB")
    height = clean_nodata(load_geotiff(fetch(VENUS_DEM, work), 4096))
    height -= np.median(height)
    probe("height_m", height, PROBES["venus"])
    write_body(out, "venus", color, height, 605_180.0, 3.0, [VENUS_RADAR[0], VENUS_DEM[0]], size)


def phobos(work, out, size):
    c = load_geotiff(fetch(PHOBOS_COLOR, work), 4096).astype(np.float32)
    if c.ndim == 3:
        c = c[..., :3].mean(axis=2)
    c = np.clip((c - np.percentile(c, 1)) / max(np.percentile(c, 99) - np.percentile(c, 1), 1.0), 0, 1)
    c = c * 0.55 + 0.1
    rgb = np.stack([c * 1.0, c * 0.93, c * 0.85], axis=-1)
    color = Image.fromarray((rgb * 255).clip(0, 255).astype(np.uint8), mode="RGB")
    d = load_geotiff(fetch(PHOBOS_DEM, work), 4096).astype(np.float32)
    if d.ndim == 3:
        d = d[..., 0]
    d = clean_nodata(d)
    med = float(np.median(d))
    print("  phobos dem median", med, flush=True)
    if med > 5000:          # radius in metres
        height = d - 11_270.0
    elif med > 5:           # radius in km
        height = (d - 11.27) * 1000.0
    else:                   # already relative
        height = d - med
    probe("height_m", height, PROBES["phobos"])
    write_body(out, "phobos", color, height, 1_127.0, 1.0, [PHOBOS_COLOR[0], PHOBOS_DEM[0]], (size[0] // 2, size[1] // 2))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--work", required=True)
    ap.add_argument("--width", type=int, default=2048)
    ap.add_argument("--bodies", default="all")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    os.makedirs(a.work, exist_ok=True)
    size = (a.width, a.width // 2)
    ok = True
    fns = {"earth": earth, "moon": moon, "mars": mars, "mercury": mercury, "venus": venus, "phobos": phobos}
    pick = list(fns) if a.bodies == "all" else [b.strip() for b in a.bodies.split(",")]
    for fn in [fns[b] for b in pick]:
        try:
            fn(a.work, a.out, size)
        except BaseException as e:  # keep going so one body's failure doesn't hide the other
            print("FAILED", fn.__name__, e, flush=True)
            ok = False
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
