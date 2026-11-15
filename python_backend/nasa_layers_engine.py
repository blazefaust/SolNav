"""
nasa_layers_engine.py — Zero-download NASA/USGS layer streaming for the Mars Mission Planner.

Nothing is written to disk: every layer is fetched over HTTP for the requested
region only, held in a small in-memory LRU cache, and returned as an RGBA array
aligned with the MOLA region of interest (ROI).

Each layer reports its PROVENANCE so the UI can be honest about what is shown:
  "streamed" - real imagery pulled live from a NASA/USGS service
  "modeled"  - derived from the MOLA elevation grid (no public image service exists
               for it); a plausibility model, NOT measured data
  "none"     - could not be produced (see `note`)

Verified live sources (checked against USGS / NASA documentation):
  * USGS Astrogeology WMS   https://planetarymaps.usgs.gov/cgi-bin/mapserv?map=/maps/mars/mars_simp_cyl.map
        layers: MDIM21 (Viking mosaic), THEMIS_IR_Day, THEMIS_IR_Night
        (the old code used mars_simplex.map / "Mars_CTX_Mosaic" / "MOLA_Color", which
         do not exist, which is why nothing ever streamed)
  * NASA Mars Trek WMTS     https://trek.nasa.gov/tiles/Mars/EQ/<layer>/1.0.0/default/default028mm/{z}/{row}/{col}.jpg
        layer: Viking_MDIM21_ClrMosaic_global_232m  (used as a redundancy fallback)

CTX and HiRISE:
  The Murray Lab global CTX mosaic (5 m/px) is streamable through Esri's ArcGIS
  Online ("Global CTX Mosaic of Mars (V01)"). HiRISE has no global mosaic at all.
  Set these environment variables to the REST URL of an ArcGIS ImageServer or
  MapServer to enable them:
        MARS_CTX_URL      MARS_HIRISE_URL
  Without them, those toggles fall back to the best verified streamed imagery
  (THEMIS ~100 m) and say so in the response.
"""
import logging
import math
import os
import threading
import time
from collections import OrderedDict
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from io import BytesIO
from typing import Any, Dict, List, Optional, Tuple

import numpy as np
import requests
from PIL import Image

logger = logging.getLogger("NasaLayersEngine")

USGS_MARS_WMS = "https://planetarymaps.usgs.gov/cgi-bin/mapserv?map=/maps/mars/mars_simp_cyl.map"
TREK_MARS_EQ = "https://trek.nasa.gov/tiles/Mars/EQ"

METERS_PER_DEG = 59150.0
MAX_FETCH_PX = 2048            # largest single WMS request edge; result is resampled to the ROI
LRU_SIZE = 24
PROBE_TTL_S = 300.0


# --------------------------------------------------------------------------- #
# Source definitions
# --------------------------------------------------------------------------- #
@dataclass(frozen=True)
class Source:
    kind: str                  # "wms" | "wmts" | "arcgis"
    label: str                 # shown to the user
    url: str
    layer: str = ""
    ext: str = "jpg"


def _env_arcgis(var: str, label: str) -> List[Source]:
    url = os.environ.get(var, "").strip().rstrip("/")
    return [Source("arcgis", label, url)] if url else []


_OPTICAL_FALLBACKS: List[Source] = [
    Source("wms", "THEMIS Day IR (~100 m, USGS WMS)", USGS_MARS_WMS, "THEMIS_IR_Day"),
    Source("wms", "Viking MDIM 2.1 (~230 m, USGS WMS)", USGS_MARS_WMS, "MDIM21"),
    Source("wmts", "Viking MDIM 2.1 color (~230 m, NASA Mars Trek)", TREK_MARS_EQ,
           "Viking_MDIM21_ClrMosaic_global_232m", "jpg"),
]


def source_chain(layer_id: str) -> List[Source]:
    if layer_id == "ctx":
        return _env_arcgis("MARS_CTX_URL", "Global CTX Mosaic (5 m, ArcGIS)") + _OPTICAL_FALLBACKS
    if layer_id == "hirise":
        return (_env_arcgis("MARS_HIRISE_URL", "HiRISE (ArcGIS)") +
                _env_arcgis("MARS_CTX_URL", "Global CTX Mosaic (5 m, ArcGIS)") +
                _OPTICAL_FALLBACKS)
    return []


STREAMED_LAYERS = ("ctx", "hirise")
MODELED_LAYERS = ("crism", "mcs", "sharad")

LAYER_INFO: Dict[str, Dict[str, Any]] = {
    "mola":   {"name": "MOLA Topography",     "agency": "NASA MGS/MOLA MEGDR", "default_opacity": 1.0},
    "hirise": {"name": "HiRISE Imagery",      "agency": "NASA MRO/HiRISE",     "default_opacity": 0.90},
    "ctx":    {"name": "CTX Imagery",         "agency": "NASA MRO/CTX",        "default_opacity": 0.85},
    "mcs":    {"name": "Mars Climate (MCS)",  "agency": "NASA MRO/MCS",        "default_opacity": 0.55},
    "sharad": {"name": "Subsurface Radar",    "agency": "NASA MRO/SHARAD",     "default_opacity": 0.60},
    "crism":  {"name": "Mineral Composition", "agency": "NASA MRO/CRISM",      "default_opacity": 0.55},
}


# --------------------------------------------------------------------------- #
# Legends (shown on the 2D render AND returned by the API for the Flutter UI)
# --------------------------------------------------------------------------- #
def _hex(rgb) -> str:
    return "#%02x%02x%02x" % tuple(int(round(max(0.0, min(255.0, float(c))))) for c in rgb)


def _mcs_rgb(t: float):
    """Same colour math as NasaLayersEngine.synthesize_mcs for normalised temperature t in 0..1."""
    return (t * 255.0, (1.0 - abs(t - 0.5) * 2.0) * 180.0, (1.0 - t) * 255.0)


def legend_for(layer_id: str, source: Optional[str] = None) -> Optional[Dict[str, Any]]:
    """
    {"type": "gradient", "title", "stops": [{"pos": 0..1, "color": "#rrggbb", "label"}], "caption"}
    {"type": "categories", "title", "items": [{"color", "label"}], "caption"}
    Keep the thresholds below in sync with synthesize_crism / synthesize_mcs / synthesize_sharad.
    """
    src = source or ""
    if layer_id in STREAMED_LAYERS:
        lo, hi = "darker", "brighter"
        if "THEMIS" in src:
            cap = "Daytime thermal infrared: brightness ~ surface temperature (bright = warmer, dark = cooler)."
            lo, hi = "cooler", "warmer"
        elif "MDIM" in src or "Viking" in src:
            cap = "Viking orbiter mosaic: brightness ~ visible reflectance (surface albedo plus shading)."
        elif "CTX" in src or "HiRISE" in src:
            cap = "Grayscale visible image: brightness = surface reflectance; very dark = shadow or dark material."
        else:
            cap = "Brightness of the streamed image (not a calibrated measurement)."
        return {"type": "gradient", "title": "Image brightness",
                "stops": [{"pos": 0.0, "color": "#000000", "label": lo},
                          {"pos": 1.0, "color": "#ffffff", "label": hi}],
                "caption": cap}
    if layer_id == "crism":
        return {"type": "categories", "title": "Mineral class (modeled)",
                "items": [
                    {"color": _hex((210, 0, 0)),   "label": "Iron oxides: high ground above 1,200 m"},
                    {"color": _hex((0, 190, 0)),   "label": "Clays (phyllosilicates): deep basins below -1,500 m"},
                    {"color": _hex((0, 0, 230)),   "label": "Mafic rock (olivine / pyroxene): slopes steeper than 14 deg"},
                    {"color": _hex((120, 200, 0)), "label": "Sulfates: gentle slopes 5-14 deg, -1,500 to 500 m"},
                ],
                "caption": "Brighter tint = stronger signal. Overlaps blend colours."}
    if layer_id == "mcs":
        temps = (140.0, 172.5, 205.0, 237.5, 270.0)
        return {"type": "gradient", "title": "Surface temperature (modeled)",
                "stops": [{"pos": (T - 140.0) / 130.0,
                           "color": _hex(_mcs_rgb((T - 140.0) / 130.0)),
                           "label": f"{T:.0f} K\n{T - 273.15:.0f} \u00b0C"} for T in temps],
                "caption": "Blue = cold, red = warm. Model: latitude sunlight + cooling with altitude."}
    if layer_id == "sharad":
        return {"type": "gradient", "title": "Radar return (modeled)",
                "stops": [{"pos": 0.0, "color": _hex((0, 0, 0)), "label": "weak"},
                          {"pos": 1.0, "color": _hex((25.5, 229.5, 178.5)), "label": "strong"}],
                "caption": "Smooth ground and deep basins score higher. Plausibility only, not radar data."}
    return None


class NasaLayersEngine:
    MARS_LAPSE_RATE_K_PER_M = 0.0062
    MARS_DATUM_TEMP_K = 210.0
    MARS_ATM_PRESSURE_PA = 610.0

    def __init__(self):
        self.session = requests.Session()
        self.session.headers.update({
            "User-Agent": "MarsMissionPlanner/2.5 (NASA Space Apps; planetary exploration workstation)"})
        self._cache: "OrderedDict[tuple, Tuple[np.ndarray, str]]" = OrderedDict()
        self._lock = threading.Lock()
        self._probe: Dict[str, Any] = {"t": 0.0, "data": {}}
        self._probing = False

    # ------------------------------------------------------------------ #
    # Public: one overlay for the 2D renderer
    # ------------------------------------------------------------------ #
    def get_overlay(self, layer_id: str,
                    bbox: Tuple[float, float, float, float],
                    shape: Tuple[int, int],
                    roi: Optional[np.ndarray] = None,
                    lat_ax: Optional[np.ndarray] = None,
                    lon_ax: Optional[np.ndarray] = None) -> Dict[str, Any]:
        """
        bbox  = (south, north, west, east) in degrees (east longitude, 0..360 or -180..180)
        shape = (rows, cols) of the ROI so the overlay lines up pixel-for-pixel
        Returns {id, ok, rgba (H,W,4 float32 0..1 | None), provenance, source, note}.
        """
        info = LAYER_INFO.get(layer_id)
        if info is None:
            return self._fail(layer_id, f"Unknown layer '{layer_id}'.")
        if layer_id == "mola":
            return self._fail(layer_id, "MOLA is the base layer.", ok=True)

        if layer_id in STREAMED_LAYERS:
            got = self._stream_rgb(layer_id, bbox, shape)
            if got is None:
                return self._fail(layer_id, "All imagery services were unreachable or had no coverage here. "
                                            "Check your internet connection / firewall.")
            rgb, label = got
            if lat_ax is not None and lat_ax[0] < lat_ax[-1]:   # ROI rows run south->north; services return north-up
                rgb = rgb[::-1]
            alpha = (rgb.max(axis=-1) > 3).astype(np.float32)
            rgba = np.dstack([rgb.astype(np.float32) / 255.0, alpha])
            note = None
            if layer_id == "hirise" and "HiRISE" not in label:
                note = "HiRISE has no global streaming mosaic; showing the best available imagery instead."
            if layer_id == "ctx" and "CTX" not in label:
                note = "CTX service not configured (set MARS_CTX_URL); showing the best available imagery instead."
            return {"id": layer_id, "ok": True, "rgba": rgba, "provenance": "streamed",
                    "source": label, "note": note}

        # modeled layers need the elevation grid
        if roi is None or lat_ax is None or lon_ax is None:
            return self._fail(layer_id, "Needs the elevation region to model this layer.")
        slope = self.slope_deg(roi, lat_ax, lon_ax)
        elev = np.where(np.isnan(roi), np.nanmin(roi) if np.isfinite(roi).any() else 0.0, roi)
        if layer_id == "crism":
            rgb = self.synthesize_crism(elev, slope)
            alpha = (rgb.max(axis=-1) > 0).astype(np.float32)
        elif layer_id == "mcs":
            rgb = self.synthesize_mcs(elev, center_lat=float(np.mean(lat_ax)))
            alpha = np.ones(rgb.shape[:2], np.float32)
        else:
            rgb = self.synthesize_sharad(elev, slope)
            alpha = (rgb[..., 1].astype(np.float32) / 255.0)
        rgba = np.dstack([rgb.astype(np.float32) / 255.0, alpha])
        return {"id": layer_id, "ok": True, "rgba": rgba, "provenance": "modeled",
                "source": "Modeled from MOLA elevation (not measured data)",
                "note": "No public streaming image service exists for this instrument; "
                        "this is a terrain-based plausibility model."}

    @staticmethod
    def _fail(layer_id, note, ok=False):
        return {"id": layer_id, "ok": ok, "rgba": None, "provenance": "none", "source": None, "note": note}

    # ------------------------------------------------------------------ #
    # Streaming with failover
    # ------------------------------------------------------------------ #
    def _stream_rgb(self, layer_id, bbox, shape) -> Optional[Tuple[np.ndarray, str]]:
        key = (layer_id, tuple(round(float(v), 4) for v in bbox), tuple(shape))
        with self._lock:
            if key in self._cache:
                self._cache.move_to_end(key)
                return self._cache[key]

        rows, cols = shape
        scale = min(1.0, MAX_FETCH_PX / float(max(rows, cols, 1)))
        fw, fh = max(8, int(cols * scale)), max(8, int(rows * scale))

        result = None
        for src in source_chain(layer_id):
            try:
                if src.kind == "wms":
                    img = self._fetch_wms(src, bbox, fw, fh)
                elif src.kind == "wmts":
                    img = self._fetch_wmts(src, bbox, fw, fh)
                else:
                    img = self._fetch_arcgis(src, bbox, fw, fh)
            except Exception as e:                       # never let one source kill the render
                logger.warning("source %s failed: %s", src.label, e)
                img = None
            if img is not None:
                img = img.convert("RGB").resize((cols, rows), Image.BILINEAR)
                result = (np.asarray(img, dtype=np.uint8), src.label)
                break
            logger.info("no image from %s, trying next source", src.label)

        if result is not None:
            with self._lock:
                self._cache[key] = result
                while len(self._cache) > LRU_SIZE:
                    self._cache.popitem(last=False)
        return result

    @staticmethod
    def _is_blank(img: Image.Image) -> bool:
        a = np.asarray(img.convert("L").resize((48, 48)), dtype=np.float32)
        return a.std() < 1.5 or a.mean() < 1.0

    def _http_image(self, url, params=None, timeout=(5, 20)) -> Optional[Image.Image]:
        for attempt in (0, 1):
            try:
                r = self.session.get(url, params=params, timeout=timeout)
                if r.status_code == 200 and "image" in r.headers.get("Content-Type", ""):
                    return Image.open(BytesIO(r.content))
                logger.debug("HTTP %s from %s", r.status_code, url)
                if r.status_code in (400, 403, 404):
                    return None
            except requests.RequestException as e:
                logger.debug("attempt %d failed for %s: %s", attempt, url, e)
        return None

    # ---- WMS (USGS) ---------------------------------------------------- #
    def _fetch_wms(self, src: Source, bbox, w, h) -> Optional[Image.Image]:
        s, n, west, east = bbox
        variants = [(west, east)]                       # USGS Mars map accepts 0..360
        if west > 180 or east > 180:
            variants.append((west - 360.0, east - 360.0))   # ...or -180..180
        for lo, hi in variants:
            img = self._http_image(src.url, {
                "SERVICE": "WMS", "VERSION": "1.1.1", "REQUEST": "GetMap",
                "LAYERS": src.layer, "STYLES": "", "SRS": "EPSG:4326",
                "BBOX": f"{lo},{s},{hi},{n}", "WIDTH": str(w), "HEIGHT": str(h),
                "FORMAT": "image/png",
            })
            if img is not None and not self._is_blank(img):
                return img
        return None

    # ---- WMTS (NASA Mars Trek, equirectangular) ------------------------ #
    def _fetch_wmts(self, src: Source, bbox, w, h) -> Optional[Image.Image]:
        s, n, west, east = bbox
        west = ((west + 180.0) % 360.0) - 180.0
        east = west + (bbox[3] - bbox[2])
        span = max(east - west, 1e-6)

        # pick the coarsest zoom that still gives >= w pixels across the region, capped at 48 tiles
        zoom = 0
        for z in range(0, 9):
            cols_z = 2 ** (z + 1)
            zoom = z
            if (span / 360.0) * cols_z * 256 >= w:
                break
        while zoom > 0:
            cols_z, rows_z = 2 ** (zoom + 1), 2 ** zoom
            tx = (span / 360.0) * cols_z + 1
            ty = ((n - s) / 180.0) * rows_z + 1
            if tx * ty <= 48:
                break
            zoom -= 1

        cols_z, rows_z = 2 ** (zoom + 1), 2 ** zoom
        px = lambda lon: (lon + 180.0) / 360.0 * cols_z * 256
        py = lambda lat: (90.0 - lat) / 180.0 * rows_z * 256
        x0, x1 = px(west), px(east)
        y0, y1 = py(min(n, 90.0)), py(max(s, -90.0))
        c0, c1 = int(math.floor(x0 / 256)), int(math.floor((x1 - 1e-6) / 256))
        r0 = max(0, int(math.floor(y0 / 256)))
        r1 = min(rows_z - 1, int(math.floor((y1 - 1e-6) / 256)))

        jobs = [(r, c) for r in range(r0, r1 + 1) for c in range(c0, c1 + 1)]

        def get(rc):
            r, c = rc
            url = (f"{src.url}/{src.layer}/1.0.0/default/default028mm/"
                   f"{zoom}/{r}/{c % cols_z}.{src.ext}")
            return rc, self._http_image(url, timeout=(5, 15))

        with ThreadPoolExecutor(max_workers=8) as pool:
            tiles = dict(pool.map(get, jobs))
        if not any(t is not None for t in tiles.values()):
            return None

        mosaic = Image.new("RGB", ((c1 - c0 + 1) * 256, (r1 - r0 + 1) * 256), (0, 0, 0))
        for (r, c), t in tiles.items():
            if t is not None:
                mosaic.paste(t.convert("RGB").resize((256, 256)), ((c - c0) * 256, (r - r0) * 256))
        box = (x0 - c0 * 256, y0 - r0 * 256, x1 - c0 * 256, y1 - r0 * 256)
        out = mosaic.resize((w, h), Image.BILINEAR, box=box)
        return None if self._is_blank(out) else out

    # ---- ArcGIS ImageServer / MapServer (Esri-hosted CTX etc.) --------- #
    def _fetch_arcgis(self, src: Source, bbox, w, h) -> Optional[Image.Image]:
        s, n, west, east = bbox
        is_image_server = "ImageServer" in src.url
        endpoint = "exportImage" if is_image_server else "export"
        params = {"bbox": f"{west},{s},{east},{n}", "bboxSR": "4326", "imageSR": "4326",
                  "size": f"{w},{h}", "format": "png", "f": "image"}
        img = self._http_image(f"{src.url}/{endpoint}", params, timeout=(5, 30))
        return None if (img is None or self._is_blank(img)) else img

    # ------------------------------------------------------------------ #
    # Health probe for /api/layers (cached; tiny requests only)
    # ------------------------------------------------------------------ #
    def probe_async(self) -> None:
        if self._probing:
            return
        self._probing = True

        def run():
            try:
                self.probe_all(force=True)
            finally:
                self._probing = False
        threading.Thread(target=run, daemon=True).start()

    def probe_all(self, force: bool = False) -> Dict[str, Dict[str, Any]]:
        now = time.time()
        if not force and self._probe["data"] and now - self._probe["t"] < PROBE_TTL_S:
            return self._probe["data"]
        test_bbox, test_shape = (-5.0, 5.0, 100.0, 110.0), (32, 32)

        def probe(layer_id):
            got = self._stream_rgb_uncached(layer_id, test_bbox, test_shape)
            return layer_id, got

        data: Dict[str, Dict[str, Any]] = {}
        with ThreadPoolExecutor(max_workers=2) as pool:
            for lid, got in pool.map(probe, STREAMED_LAYERS):
                data[lid] = {"connected": got is not None, "source": got}
        self._probe = {"t": now, "data": data}
        return data

    def _stream_rgb_uncached(self, layer_id, bbox, shape) -> Optional[str]:
        for src in source_chain(layer_id):
            try:
                fn = {"wms": self._fetch_wms, "wmts": self._fetch_wmts, "arcgis": self._fetch_arcgis}[src.kind]
                if fn(src, bbox, shape[1], shape[0]) is not None:
                    return src.label
            except Exception:
                continue
        return None

    def status_all(self, block: bool = False) -> List[Dict[str, Any]]:
        """block=False (default) never waits on the network: it reports the last probe and refreshes
        in the background; `connected` is None while the first check is still running."""
        if block:
            probe = self.probe_all()
        else:
            probe = self._probe["data"]
            if not probe or time.time() - self._probe["t"] > PROBE_TTL_S:
                self.probe_async()
        out = []
        for lid, info in LAYER_INFO.items():
            if lid == "mola":
                row = {"connected": True, "provenance": "local", "detail": "Loaded from local MOLA tiles"}
            elif lid in STREAMED_LAYERS:
                p = probe.get(lid)
                if p is None:
                    row = {"connected": None, "provenance": "streamed", "detail": "Checking connection..."}
                else:
                    row = {"connected": bool(p["connected"]), "provenance": "streamed",
                           "detail": p["source"] or "Unreachable - check internet connection"}
            else:
                row = {"connected": True, "provenance": "modeled",
                       "detail": "Modeled from MOLA elevation (no public image service)"}
            src_label = row["detail"] if row.get("provenance") == "streamed" else None
            out.append({"id": lid, "name": info["name"], "source": info["agency"],
                        "default_opacity": info["default_opacity"],
                        "legend": legend_for(lid, src_label), **row})
        return out

    # ------------------------------------------------------------------ #
    # Terrain helpers
    # ------------------------------------------------------------------ #
    @staticmethod
    def slope_deg(roi: np.ndarray, lat_ax: np.ndarray, lon_ax: np.ndarray) -> np.ndarray:
        rows, cols = roi.shape
        dy = abs(float(lat_ax[0] - lat_ax[-1])) / max(rows - 1, 1) * METERS_PER_DEG
        cos_lat = max(0.05, math.cos(math.radians(float(np.mean(lat_ax)))))
        dx = abs(float(lon_ax[-1] - lon_ax[0])) / max(cols - 1, 1) * METERS_PER_DEG * cos_lat
        fill = float(np.nanmean(roi)) if np.isfinite(roi).any() else 0.0
        clean = np.where(np.isnan(roi), fill, roi).astype(np.float32)
        gy, gx = np.gradient(clean, max(dy, 1.0), max(dx, 1.0))
        return np.degrees(np.arctan(np.hypot(gx, gy))).astype(np.float32)

    def science_proxy(self, roi, lat_ax, lon_ax) -> np.ndarray:
        """0..1 'science interest' heuristic = diversity of modeled mineral classes. Heuristic only."""
        slope = self.slope_deg(roi, lat_ax, lon_ax)
        elev = np.where(np.isnan(roi), np.nanmin(roi), roi)
        rgb = self.synthesize_crism(elev, slope).astype(np.float32) / 255.0
        return np.clip((rgb > 0.15).sum(axis=-1) / 3.0 + 0.25 * rgb.max(axis=-1), 0.0, 1.0)

    # ------------------------------------------------------------------ #
    # MODELED layers (terrain-derived; labelled as such everywhere)
    # ------------------------------------------------------------------ #
    def synthesize_crism(self, elevation_matrix: np.ndarray, slope_matrix: np.ndarray) -> np.ndarray:
        """
        Terrain-context mineral plausibility map (NOT CRISM measurements):
        R = iron oxides on high ground, G = clays in deep basins / sulfates on gentle floors,
        B = mafic rock on steep scarps.
        """
        h, w = elevation_matrix.shape
        rgb = np.zeros((h, w, 3), dtype=np.float32)
        hi = np.clip((elevation_matrix - 1200.0) / 4000.0, 0, 1) * (elevation_matrix > 1200.0)
        rgb[..., 0] += hi * 210.0
        lo = np.clip((-1500.0 - elevation_matrix) / 3500.0, 0, 1) * (elevation_matrix < -1500.0)
        rgb[..., 1] += lo * 190.0
        steep = np.clip((slope_matrix - 14.0) / 25.0, 0, 1) * (slope_matrix > 14.0)
        rgb[..., 2] += steep * 230.0
        sulfate = ((elevation_matrix >= -1500.0) & (elevation_matrix <= 500.0) &
                   (slope_matrix > 5.0) & (slope_matrix <= 14.0)).astype(np.float32)
        rgb[..., 0] += sulfate * 120.0
        rgb[..., 1] += sulfate * 200.0
        return np.clip(rgb, 0, 255).astype(np.uint8)

    def synthesize_mcs(self, elevation_matrix: np.ndarray, center_lat: float = 0.0) -> np.ndarray:
        """Surface temperature model: latitude insolation + lapse-rate cooling (blue cold -> red warm)."""
        base = self.MARS_DATUM_TEMP_K + math.cos(math.radians(center_lat)) * 25.0
        temp = np.clip(base - elevation_matrix * self.MARS_LAPSE_RATE_K_PER_M, 140.0, 270.0)
        t = (temp - 140.0) / (270.0 - 140.0)
        out = np.zeros(elevation_matrix.shape + (3,), dtype=np.uint8)
        out[..., 0] = (t * 255.0).astype(np.uint8)
        out[..., 1] = ((1.0 - np.abs(t - 0.5) * 2.0) * 180.0).astype(np.uint8)
        out[..., 2] = ((1.0 - t) * 255.0).astype(np.uint8)
        return out

    def synthesize_sharad(self, elevation_matrix: np.ndarray, slope_matrix: np.ndarray) -> np.ndarray:
        """Radar-return plausibility: smooth ground and deep basins score higher (NOT SHARAD data)."""
        smooth = np.clip(1.0 - slope_matrix / 15.0, 0.0, 1.0)
        basin = (elevation_matrix < -1000.0).astype(np.float32)
        r = (smooth * 0.6 + basin * 0.4) * 255.0
        out = np.zeros(elevation_matrix.shape + (3,), dtype=np.uint8)
        out[..., 0] = (r * 0.1).astype(np.uint8)
        out[..., 1] = (r * 0.9).astype(np.uint8)
        out[..., 2] = (r * 0.7).astype(np.uint8)
        return out

    def calculate_atmospheric_pressure(self, elevation_matrix: np.ndarray) -> np.ndarray:
        return self.MARS_ATM_PRESSURE_PA * np.exp(-elevation_matrix / 11100.0)

    @staticmethod
    def blend_layers(base_rgb: np.ndarray, overlay_rgb: np.ndarray, opacity: float = 0.5) -> np.ndarray:
        a = float(np.clip(opacity, 0.0, 1.0))
        return np.clip(base_rgb.astype(np.float32) * (1 - a) + overlay_rgb.astype(np.float32) * a,
                       0, 255).astype(np.uint8)