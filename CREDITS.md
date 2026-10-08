# Credits

Ассеты — либо сгенерированы кодом (процедурные меши, шумовые текстуры, шейдеры), либо NASA public domain.

| Ассет | Источник | Лицензия |
|---|---|---|
| `icon.svg` | нарисован вручную для проекта | собственный |
| Звёздное небо, планета на экране загрузки, мелкий рельеф | генерируются шейдером / `FastNoiseLite` | собственный |
| `assets/planets/earth_color.jpg` | NASA Earth Observatory, Blue Marble: Next Generation (Reto Stöckli, NASA GSFC), декабрь 2004 — https://visibleearth.nasa.gov/collection/1484/blue-marble | NASA, public domain |
| `assets/planets/earth_height.bin`, `earth_normal.png` | NASA Earth Observatory, рендеры GEBCO_08 (рельеф суши и батиметрия) — https://visibleearth.nasa.gov/images/73934 , https://visibleearth.nasa.gov/images/73963 | NASA, public domain (данные GEBCO) |
| `assets/planets/moon_color.jpg` | NASA SVS, CGI Moon Kit — цветная карта LRO LROC WAC (Ernie Wright, NASA GSFC) — https://svs.gsfc.nasa.gov/4720 | NASA, public domain |
| `assets/planets/moon_height.bin`, `moon_normal.png` | NASA SVS, CGI Moon Kit — карта высот LRO LOLA (`ldem_16`) — https://svs.gsfc.nasa.gov/4720 | NASA, public domain |

Карты скачиваются и уменьшаются workflow `.github/workflows/fetch-planet-maps.yml` (`tools/fetch_planet_maps.py`).

Движок: [Godot Engine](https://godotengine.org) — MIT.
