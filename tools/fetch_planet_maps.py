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

EARTH_COLOR = [
    "https://eoimages.gsfc.nasa.gov/images/imagerecords/74000/74218/world.200412.3x5400x2700.jpg",
    "https://eoimages.gsfc.nasa.gov/images/imagerecords/73000/73909/world.topo.bathy.200412.3x5400x2700.jpg",
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

PROBES = {
    "earth": {"Everest": (27.99, 86.93), "Mariana": (11.35, 142.2), "Baikonur": (45.97, 63.3),
              "Amazon": (-3.0, -60.0), "MidAtlantic": (0.0, -25.0), "Tibet": (32.0, 90.0),
              "DeadSea": (31.5, 35.5), "Greenland": (72.0, -40.0)},
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


def load_array(path):
    if path.lower().endswith((".tif", ".tiff")):
        import tifffile
        a = tifffile.imread(path)
    else:
        a = np.asarray(Image.open(path))
    print("  loaded", os.path.basename(path), a.shape, a.dtype, "min", a.min(), "max", a.max(), flush=True)
    return a


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
    color = Image.open(fetch(EARTH_COLOR, work))
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
    write_body(out, "earth", color, height, 637_100.0, 6.0,
               [EARTH_COLOR[0], EARTH_ELEV[0], EARTH_BATH[0]], size)


def moon(work, out, size):
    color = Image.open(fetch(MOON_COLOR, work))
    dem = load_array(fetch(MOON_DEM, work)).astype(np.float32)
    if dem.ndim == 3:
        dem = dem[..., 0]
    # CGI Moon Kit ldem_*: kilometres relative to 1737.4 km.
    height = dem * 1000.0 if np.abs(dem).max() < 50 else dem
    probe("height_m", height, PROBES["moon"])
    write_body(out, "moon", color, height, 173_740.0, 3.0, [MOON_COLOR[0], MOON_DEM[0]], size)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--work", required=True)
    ap.add_argument("--width", type=int, default=2048)
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    os.makedirs(a.work, exist_ok=True)
    size = (a.width, a.width // 2)
    ok = True
    for fn in (earth, moon):
        try:
            fn(a.work, a.out, size)
        except BaseException as e:  # keep going so one body's failure doesn't hide the other
            print("FAILED", fn.__name__, e, flush=True)
            ok = False
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
