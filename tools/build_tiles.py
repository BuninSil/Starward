#!/usr/bin/env python3
"""High-resolution colour tiles for close-up ground (downloaded by the game on demand).

Builds an equirectangular colour map of `--width` pixels (north up, longitude
-180..180) for one body, applies the same colour treatment as the global map
(tools/fetch_planet_maps.py) and cuts it into TILE x TILE JPEG tiles:
  out/<id>_<col>_<row>.jpg, out/<id>_tiles.json
The workflow .github/workflows/build-map-tiles.yml publishes them as a
prerelease `maps-<id>-v1` (never "latest", so the in-game updater ignores it).
"""
import argparse
import json
import os
import re
import sys

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(__file__))
import fetch_planet_maps as fpm  # noqa: E402

Image.MAX_IMAGE_PIXELS = None
TILE = 1024

EARTH_PAGES = fpm.VISIBLE_EARTH_PAGES
EARTH_TILE_RE = r"world\.topo\.bathy\.200407\.3x21600x21600\.([ABCD])([12])\.jpg"
MOON_DIR = "https://svs.gsfc.nasa.gov/vis/a000000/a004700/a004720/"


def _scrape(urls, pattern):
    found = []
    for u in urls:
        try:
            html = fpm._get_text(u)
        except Exception as e:
            print("  scrape failed", u, e, flush=True)
            continue
        for m in re.finditer(r'(https?://[^"\'\s<>]+)?/?([^"\'\s<>/]*' + pattern + ")", html):
            full = m.group(0)
            if not full.startswith("http"):
                full = u.rstrip("/") + "/" + m.group(2)
            found.append(full)
    return list(dict.fromkeys(found))


EARTH_REC = "https://eoimages.gsfc.nasa.gov/images/imagerecords/73000/73751/"


def earth(work, width):
    # Blue Marble July, 8 tiles of 21600² (A1 = 90N..0, 180W..90W; A2 = 0..90S; B.. east).
    q = width // 4
    out = Image.new("RGB", (width, width // 2))
    try:
        for col, letter in enumerate("ABCD"):
            for row in (1, 2):
                name = "world.topo.bathy.200407.3x21600x21600.%s%d.jpg" % (letter, row)
                path = fpm.fetch([EARTH_REC + name], work)
                im = Image.open(path)
                im.draft("RGB", (q * 2, q * 2))   # fast JPEG downscale on decode
                im = im.convert("RGB").resize((q, q), Image.LANCZOS)
                out.paste(im, (col * q, (row - 1) * q))
                os.remove(path)
                print("  placed", letter, row, flush=True)
        return out
    except SystemExit:
        print("  direct record failed, scraping", flush=True)
    pages = []
    for p in EARTH_PAGES:
        try:
            html = fpm._get_text(p)
        except Exception as e:
            print("  page failed", p, e, flush=True)
            continue
        for m in re.finditer(r'href="(/images/\d+/july[^"]*)"', html):
            pages.append("https://visibleearth.nasa.gov" + m.group(1))
    urls = _scrape(list(dict.fromkeys(pages)), EARTH_TILE_RE)
    print("  earth tiles found:", urls, flush=True)
    by_key = {}
    for u in urls:
        m = re.search(EARTH_TILE_RE, u)
        if m and u.startswith("https://eoimages"):
            by_key[m.group(1) + m.group(2)] = u
    if len(by_key) < 8:
        raise SystemExit("Blue Marble 21600 tiles not found: %s" % sorted(by_key))
    q = width // 4
    out = Image.new("RGB", (width, width // 2))
    for col, letter in enumerate("ABCD"):
        for row in (1, 2):
            path = fpm.fetch([by_key[letter + str(row)]], work)
            im = Image.open(path)
            im.draft("RGB", (q * 2, q * 2))   # fast JPEG downscale on decode
            im = im.convert("RGB").resize((q, q), Image.LANCZOS)
            out.paste(im, (col * q, (row - 1) * q))
            os.remove(path)
            print("  placed", letter, row, flush=True)
    return out


def moon(work, width):
    path = fpm.fetch([MOON_DIR + "lroc_color_poles_%dk.tif" % k for k in (16, 8, 4)], work)
    print("  moon colour:", os.path.basename(path), flush=True)
    a = fpm.load_geotiff(path, 32768)
    if a.dtype != np.uint8:
        a = (a.astype(np.float32) / (65535.0 if a.max() > 255 else 255.0) * 255.0).clip(0, 255).astype(np.uint8)
    return Image.fromarray(a[..., :3])


def mars(work, width):
    cp = fpm.fetch(fpm.MARS_COLOR, work)
    return Image.open(cp).convert("RGB")


def mercury(work, width):
    c = fpm.load_geotiff(fpm.fetch(fpm.MERCURY_COLOR, work), 24000)
    lum = c[..., :3].astype(np.float32).mean(axis=2) if c.ndim == 3 else c.astype(np.float32)
    lum = fpm.calm_poles(fpm.fill_gaps(lum, lum > 2.0), 70.0)
    lo, hi = np.percentile(lum, 1), np.percentile(lum, 99)
    lum = np.clip((lum - lo) / max(hi - lo, 1.0), 0, 1) * 0.75 + 0.12
    rgb = np.stack([lum, lum * 0.95, lum * 0.88], axis=-1)
    return Image.fromarray((rgb * 255).clip(0, 255).astype(np.uint8))


def venus(work, width):
    r = fpm.load_geotiff(fpm.fetch(fpm.VENUS_RADAR, work), 24000).astype(np.float32)
    if r.ndim == 3:
        r = r[..., 0]
    r = fpm.calm_poles(fpm.fill_gaps(r, r > 2.0), 75.0)
    lo, hi = np.percentile(r, 1), np.percentile(r, 99)
    r = np.clip((r - lo) / max(hi - lo, 1.0), 0, 1)
    rgb = np.stack([0.30 + 0.55 * r, 0.20 + 0.40 * r, 0.10 + 0.22 * r], axis=-1)
    return Image.fromarray((rgb * 255).clip(0, 255).astype(np.uint8))


BODIES = {"earth": earth, "moon": moon, "mars": mars, "mercury": mercury, "venus": venus}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--body", required=True, choices=sorted(BODIES))
    ap.add_argument("--width", type=int, default=16384)
    ap.add_argument("--out", required=True)
    ap.add_argument("--work", required=True)
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    os.makedirs(a.work, exist_ok=True)
    img = BODIES[a.body](a.work, a.width)
    w = a.width
    h = w // 2
    if img.size != (w, h):
        img = img.resize((w, h), Image.LANCZOS)
    cols, rows = w // TILE, h // TILE
    for r in range(rows):
        for c in range(cols):
            tile = img.crop((c * TILE, r * TILE, (c + 1) * TILE, (r + 1) * TILE))
            tile.save(os.path.join(a.out, "%s_%d_%d.jpg" % (a.body, c, r)), quality=84, optimize=True)
    meta = {"id": a.body, "width": w, "height": h, "tile": TILE, "cols": cols, "rows": rows,
            "rows_order": "north_to_south", "cols_order": "lon_-180_to_180"}
    with open(os.path.join(a.out, "%s_tiles.json" % a.body), "w") as f:
        json.dump(meta, f)
    print("tiles written:", meta, flush=True)


if __name__ == "__main__":
    main()
