# SolNav

SolNav (formerly Mars Mission Planner) is a tool for looking at Mars terrain and planning rover routes across it. It was built for NASA Space Apps 2026.

You pick a region of Mars, and the app renders it as a 2D map or an interactive 3D surface using real elevation data from NASA's MOLA instrument. From there you can pull up terrain stats, switch NASA data layers on and off, and plan a route between two points. The route planner gives you four options (recommended, shortest, safest, lowest energy), shows an elevation profile, and can play the drive back with a little rover marker.

There's also a 3D globe of Mars (Three.js) bundled in as the "Mars Globe" tab.

## How it's put together

Two parts, which talk to each other over HTTP.

- `python_backend/` is a FastAPI server. It reads the MOLA raster files, does the terrain math, renders the 2D images and 3D HTML views, plans routes, and proxies requests to NASA so the app doesn't have to download big layers itself.
- `flutter_app/` is the front end. Same code runs on Android, iOS and desktop. On phones it's locked to landscape.

```
mars_mission_planner/
├── python_backend/
│   ├── main.py            API routes
│   ├── mola_engine.py     reads MOLA data, computes stats
│   ├── renderer_2d.py     2D map images
│   ├── renderer_3d.py     3D terrain pages
│   ├── route_engine.py    route planning
│   ├── nasa_proxy.py      NASA layer requests
│   ├── cache_manager.py
│   ├── models.py
│   ├── data/              put MOLA .img + .xml files here
│   ├── cache/             created automatically
│   └── generated/         created automatically (PNGs and HTML)
└── flutter_app/
    └── lib/
        ├── screens/       dashboard, 2D map, 3D, region select, layers,
        │                  analysis, mission planning, globe
        ├── widgets/       shell/navigation and shared UI pieces
        ├── providers/     Riverpod state
        ├── services/      backend_service.dart (talks to the API)
        └── models/
```

## How it works

**Terrain.** The backend loads MOLA elevation tiles (the MEGDR gridded product) and reads their XML labels to work out each tile's bounds and resolution. When you choose a region, it crops the raster to that box and computes the numbers you see in the app: min, max and mean elevation, slope from the elevation gradient, how much of the area is flat (under 5°) or steep (over 20°), plus the area and size in kilometres.

**Maps and 3D.** The 2D view is an image the backend draws from the cropped elevation, with any switched-on data layers composited over it. The 3D view is a Plotly WebGL page built from the same crop. Vertical exaggeration is just a multiplier on elevation, so 1.0x is true scale.

**Data layers.** Extra NASA layers are requested through the backend's proxy and streamed into the map, so the phone doesn't download the large source files itself.

**Route planning.** The planner turns the terrain into a cost grid and finds the cheapest path between your two points. Each priority slider changes what "cheap" means:

- Safety penalises steep slopes and also sets hard limits. At full strength the rover can't enter slopes above roughly 18°, and at zero the limit is about 25°.
- Science makes cells with a higher mineral-diversity score cheaper to cross, so the route bends toward them. It needs a science layer to do anything.
- Distance sets how much each kilometre costs.
- Energy penalises climbing, since uphill metres cost far more than flat ones.
- Terrain difficulty penalises rough ground where many sub-pixels are moderately steep.

Your sliders shape the Recommended route. Shortest, Safest and Energy saver use fixed profiles so you always have something to compare against. Each route comes back with distance, ascent and descent, slope, a risk score, an ETA in sols, a rough energy figure, and turn-by-turn steps. ETA and energy are estimates from slope and distance only.

**The app.** The Flutter front end is mostly a thin client. It sends the region or route request, gets back image URLs, stats and path coordinates, and draws the route, elevation profile and rover playback itself.

## Getting the app

We've shared the APK, so there's nothing to build. Open it on an Android phone and install it. Android will probably ask you to allow installs from your browser or file manager the first time, which is normal for apps outside the Play Store. The backend is always on, so it works as soon as it opens. It runs in landscape.

## Using the app

Start on the dashboard to check the dataset loaded (the badge in the nav should say MOLA LOADED). Pick a landmark preset or type in a bounding box on the Region Select screen, then:

- **2D Map** renders the region with whatever data layers you've switched on.
- **3D Terrain** builds an interactive surface. There's a vertical exaggeration slider, since Mars relief is hard to see at true scale.
- **Analysis** computes elevation and slope statistics for the region.
- **Mission Plan** is the route planner. Set a start and destination (type them in or tap the map), adjust the priority sliders for safety, science, distance, energy and terrain difficulty, and hit Plan Routes. Results can be exported as an HTML brief (print it to PDF), GeoJSON, or CSV.

One thing worth knowing about the priority sliders: they only change the route when the terrain actually forces a trade-off. On flat ground most of them do nothing. The planner tells you when a new set of weights produced the exact same path.

## Layout notes

The UI was reworked to scale to small screens. Wide windows get a full sidebar, mid-size ones get an icon rail, and phones in landscape get the compact version with collapsible side panels. The mission planner switches to three tabs (Plan, Map, Routes) when there isn't room for three columns.

## Known rough edges

- Exporting from the mission planner on a phone saves into the app's private storage, so it's awkward to find the files. Desktop is fine.
- The embedded globe and 3D view use `webview_flutter`, which doesn't exist on Windows or Linux. On those platforms the app opens them in your browser instead.
- Route energy and ETA are rough estimates based on slope and distance only. Don't plan an actual rover with them.

## Data sources and credits

- **Elevation:** Mars Orbiter Laser Altimeter (MOLA) Mission Experiment Gridded Data Record (MEGDR), from the Mars Global Surveyor mission. Produced by the MOLA Science Team and archived by the NASA Planetary Data System (PDS) Geosciences Node at Washington University in St. Louis.
  - Data and tile layout: https://pds-geosciences.wustl.edu/missions/mgs/megdr.html
  - Mission page: https://pds-geosciences.wustl.edu/missions/mgs/index.htm
  - Data set record (MGS-M-MOLA-5-MEGDR-L3-V1.0): https://pds-geosciences.wustl.edu/mgs/urn-nasa-pds-mgs_mola_topography_derived/catalog/megdrds.cat
  - Product format document (EGDR SIS): https://pds-geosciences.wustl.edu/mgs/urn-nasa-pds-mgs_mola_topography_derived/document/egdrsis.pdf
- **Extra map layers:** streamed from NASA services through the backend proxy. [list the specific layers and services you use here]
- **Mars globe:** Three.js globe with Mars textures. [credit the texture source here, and any NASA image or article links it shows]
- **Software:** Flutter, Riverpod, FastAPI, Plotly and Three.js.

All Mars data belongs to NASA and its mission teams. This project isn't affiliated with or endorsed by NASA.

## AI tools

We used Claude (Anthropic) and Gemini (Google) to help debug during development.
