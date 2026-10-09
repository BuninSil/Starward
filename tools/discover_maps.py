#!/usr/bin/env python3
"""Prints download links (and sizes) found on USGS / PDS product pages.
Run in CI (the dev sandbox cannot reach these hosts) to pick map sources."""
import re
import urllib.parse
import urllib.request

PAGES = [
    "https://astrogeology.usgs.gov/search/map/mars_viking_global_color_mosaic_925m",
    "https://astrogeology.usgs.gov/search/map/mars_viking_colorized_global_mosaic_232m",
    "https://astrogeology.usgs.gov/search/map/mercury_messenger_mdis_global_color_mosaic_665m",
    "https://astrogeology.usgs.gov/search/map/mercury_messenger_mdis_global_mosaic_250m",
    "https://astrogeology.usgs.gov/search/map/mercury_messenger_global_dem_665m",
    "https://astrogeology.usgs.gov/search/map/venus_magellan_global_c3_mdir_mosaic_2025m",
    "https://astrogeology.usgs.gov/search/map/venus_magellan_global_topography_4641m",
    "https://astrogeology.usgs.gov/search/map/phobos_viking_global_mosaic_5m",
    "https://astrogeology.usgs.gov/search/map/phobos_mars_express_hrsc_dem_global_100m",
    "https://astrogeology.usgs.gov/search/map/deimos_viking_global_mosaic_25m",
    "https://astrogeology.usgs.gov/search/results?q=deimos",
    "https://pds-geosciences.wustl.edu/mgs/urn-nasa-pds-mgs_mola_topography_derived/meg004/",
    "https://pds-geosciences.wustl.edu/mgs/mgs-m-mola-5-megdr-l3-v1/mgsl_300x/meg004/",
]
LINK = re.compile(r'(https?://[^"\'\s<>]+?\.(?:tif|tiff|img|jpg|png|cub|lbl|xml))|href="([^"]+?\.(?:tif|tiff|img|jpg|png))"', re.I)


def get(u, method="GET"):
    req = urllib.request.Request(u, headers={"User-Agent": "Starward-map-fetch"}, method=method)
    return urllib.request.urlopen(req, timeout=60)


for p in PAGES:
    print("=== ", p, flush=True)
    try:
        html = get(p).read().decode("utf-8", "replace")
    except Exception as e:
        print("  page failed:", e, flush=True)
        continue
    seen = set()
    for m in LINK.finditer(html):
        u = m.group(1) or urllib.parse.urljoin(p, m.group(2))
        if u in seen or u.lower().endswith((".xml",)) and "pds" not in p:
            continue
        seen.add(u)
        size = "?"
        if u.lower().endswith((".tif", ".tiff", ".img", ".jpg", ".png")):
            try:
                r = get(u, "HEAD")
                size = "%.1f MB" % (int(r.headers.get("Content-Length", "0")) / 1e6)
            except Exception as e:
                size = "HEAD failed: %s" % e
        print("  ", u, size, flush=True)
