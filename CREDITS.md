# Credits

Ассеты — либо сгенерированы кодом (процедурные меши, шумовые текстуры, шейдеры), либо NASA public domain.

| Ассет | Источник | Лицензия |
|---|---|---|
| `icon.svg` | нарисован вручную для проекта | собственный |
| Звёздное небо, планета на экране загрузки, мелкий рельеф | генерируются шейдером / `FastNoiseLite` | собственный |
| `assets/planets/earth_color.jpg` | NASA Earth Observatory, Blue Marble: Next Generation с рельефом и батиметрией (Reto Stöckli, NASA GSFC), июль 2004 — https://visibleearth.nasa.gov/collection/1484/blue-marble | NASA, public domain |
| `assets/planets/earth_height.bin`, `earth_normal.png`, `earth_water.png` | NASA Earth Observatory, рендеры GEBCO_08 (рельеф суши и батиметрия) — https://visibleearth.nasa.gov/images/73934 , https://visibleearth.nasa.gov/images/73963 | NASA, public domain (данные GEBCO) |
| `assets/planets/moon_color.jpg` | NASA SVS, CGI Moon Kit — цветная карта LRO LROC WAC (Ernie Wright, NASA GSFC) — https://svs.gsfc.nasa.gov/4720 | NASA, public domain |
| `assets/planets/moon_height.bin`, `moon_normal.png` | NASA SVS, CGI Moon Kit — карта высот LRO LOLA (`ldem_16`) — https://svs.gsfc.nasa.gov/4720 | NASA, public domain |

| `assets/planets/mars_color.jpg` | USGS Astrogeology / NASA, Viking MDIM 2.1 colorized global mosaic (1 km) | public domain |
| `assets/planets/mars_height.bin`, `mars_normal.png` | NASA PDS, MGS MOLA MEGDR 4 px/deg (`megt90n000cb`) | public domain |
| `assets/planets/mercury_*` | USGS Astrogeology / NASA, MESSENGER MDIS global colour mosaic 665 m (переведён в естественный серый) и USGS DEM 665 m | public domain |
| `assets/planets/venus_*` | USGS Astrogeology / NASA, Magellan C3-MDIR global mosaic 2025 m (радар, тонирован) и Magellan topography 4641 m | public domain |
| `assets/planets/phobos_*` | USGS Astrogeology, Phobos Viking mosaic 40 ppd (DLR control, P. Stooke) и Mars Express HRSC DEM 2 ppd (ESA/DLR/FU Berlin, распространяется USGS как PDS) | public domain (PDS) |

Карты скачиваются и уменьшаются workflow `.github/workflows/fetch-planet-maps.yml` (`tools/fetch_planet_maps.py`).

Движок: [Godot Engine](https://godotengine.org) — MIT.
