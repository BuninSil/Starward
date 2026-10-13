#!/usr/bin/env python3
"""Coarse tile level for the view from orbit (downloaded by the game on demand).

Level 1 is the same map at L1_WIDTH pixels (2-4x sharper than the built-in
global map), cut into the same TILE x TILE JPEG tiles:
  out/<id>_l1_<col>_<row>.jpg
Made from the full-resolution tiles (tools/build_tiles.py) already on disk, so
publishing it does not need the NASA sources again
(.github/workflows/build-map-levels.yml).
"""
import argparse
import json
import os

from PIL import Image

Image.MAX_IMAGE_PIXELS = None
L1_WIDTH = 8192


def write_l1(get_block, body, width, tile, out):
    """get_block(x, y, w, h) -> RGB image of that pixel rectangle of the full map."""
    f = width // L1_WIDTH
    if f < 2:
        print("  level 1 not needed (map is %d wide)" % width, flush=True)
        return 0
    span = tile * f
    cols, rows = L1_WIDTH // tile, L1_WIDTH // 2 // tile
    for r in range(rows):
        for c in range(cols):
            im = get_block(c * span, r * span, span, span).resize((tile, tile), Image.LANCZOS)
            im.save(os.path.join(out, "%s_l1_%d_%d.jpg" % (body, c, r)), quality=86, optimize=True)
    print("  level 1: %dx%d tiles" % (cols, rows), flush=True)
    return cols * rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--body", required=True)
    ap.add_argument("--tiles", required=True, help="directory with <id>_<c>_<r>.jpg and <id>_tiles.json")
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    with open(os.path.join(a.tiles, "%s_tiles.json" % a.body)) as fh:
        meta = json.load(fh)
    t = meta["tile"]

    def block(x, y, w, h):
        img = Image.new("RGB", (w, h))
        for ty in range(y // t, (y + h) // t):
            for tx in range(x // t, (x + w) // t):
                tile = Image.open(os.path.join(a.tiles, "%s_%d_%d.jpg" % (a.body, tx, ty))).convert("RGB")
                img.paste(tile, (tx * t - x, ty * t - y))
        return img

    write_l1(block, a.body, meta["width"], t, a.out)


if __name__ == "__main__":
    main()
