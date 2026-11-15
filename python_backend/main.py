"""FastAPI backend wiring Flutter -> MOLA engines (multi-tile) + NASA streaming layers + route planner."""
import matplotlib
matplotlib.use("Agg")

import hashlib
import json
import pathlib
import re
import traceback
from concurrent.futures import ThreadPoolExecutor
from typing import Any, Dict, List, Optional, Tuple

from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from PIL import Image
from pydantic import BaseModel, ConfigDict

from nasa_proxy import router as nasa_router

from mola_engine import (
    LANDMARKS, load_mola_dataset, crop_roi, effective_ppd,
    export_heightmap_16bit, compute_terrain_statistics,
)
from renderer_2d import render_2d_hillshade
from renderer_3d import render_3d_plotly
from cache_manager import RenderCache
from models import RegionBounds, RenderRequest, StatusResponse
from nasa_layers_engine import NasaLayersEngine, LAYER_INFO, STREAMED_LAYERS, legend_for
from route_engine import plan_routes

BASE = pathlib.Path(__file__).parent
DATA_DIR = BASE / "data"
GEN_DIR = BASE / "generated"
CACHE_DIR = BASE / "cache"
GEN_DIR.mkdir(exist_ok=True)
CACHE_DIR.mkdir(exist_ok=True)
DATA_DIR.mkdir(exist_ok=True)
SOLNAV_DIR = BASE / "solnav_web"

# Pixel budgets so huge regions (e.g. all of Mars at 128 ppd) stay renderable
MAX_PIXELS_2D = 9_000_000
MAX_PIXELS_3D = 1_000_000
MAX_PIXELS_ROUTE = 2_000_000      # route grid is downsampled to ~240 cells anyway
MAX_PIXELS_ROUTE_MAP = 4_000_000

app = FastAPI(title="Mars Mission Planner Backend", version="1.2.0")
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])
app.mount("/files", StaticFiles(directory=str(GEN_DIR)), name="files")

app.include_router(nasa_router)
if SOLNAV_DIR.exists():
    app.mount("/solnav", StaticFiles(directory=str(SOLNAV_DIR), html=True), name="solnav")
else:
    print(f"[WARN] SolNav files not found at {SOLNAV_DIR}")

cache = RenderCache(CACHE_DIR)
LAYERS = NasaLayersEngine()          # streams NASA/USGS imagery on demand, nothing stored on disk
STATE = {"dataset": None, "meta": None}

LAYER_ORDER = ["ctx", "hirise", "crism", "mcs", "sharad"]      # draw order, bottom -> top


# --------------------------------------------------------------------------- #
# Request models (subclass the existing ones so models.py does not need editing)
# --------------------------------------------------------------------------- #
class RenderRequestV2(RenderRequest):
    layers: Optional[Any] = None                 # ["ctx","crism"] or {"ctx": true, ...}
    layer_opacity: Optional[Dict[str, float]] = None
    routes: Optional[List[Dict[str, Any]]] = None
    markers: Optional[List[Dict[str, Any]]] = None
    map_only: Optional[bool] = False             # borderless high-res PNG for a zoomable viewer
    max_dim: Optional[int] = None                # longest side in px for map_only (default 6000, max 8000)


class RouteBody(BaseModel):
    """Google-Maps-style request: start + destination + mission weights.
    Accepts several naming styles so the Flutter client does not have to match exactly."""
    model_config = ConfigDict(extra="allow")
    start_lat: Optional[float] = None
    start_lon: Optional[float] = None
    end_lat: Optional[float] = None
    end_lon: Optional[float] = None
    start: Optional[Any] = None                  # [lat, lon] or {"lat":..,"lon":..}
    end: Optional[Any] = None
    priorities: Optional[Dict[str, float]] = None
    max_slope_deg: float = 25.0
    region: Optional[RegionBounds] = None
    layers: Optional[Any] = None
    layer_opacity: Optional[Dict[str, float]] = None
    render: bool = True                          # also draw the map PNG with the routes on it
    map_only: bool = False                       # borderless high-res map (legends in a separate PNG)
    max_dim: Optional[int] = None
    title: Optional[str] = None


# --------------------------------------------------------------------------- #
# Helpers
# --------------------------------------------------------------------------- #
def _ensure_loaded(force: bool = False):
    if force or STATE["dataset"] is None:
        print(f"[INFO] Searching: {DATA_DIR.resolve()}")
        print(f"[INFO] Contents: {[p.name for p in DATA_DIR.iterdir()]}")
        try:
            ds = load_mola_dataset(DATA_DIR)
        except (FileNotFoundError, ValueError) as e:
            raise HTTPException(503, detail=str(e))
        STATE.update(dataset=ds, meta=ds.meta)


def _roi_meta(roi, lat_ax):
    """Dataset meta with map_resolution replaced by the ROI's real ppd
    (the ROI may be downsampled to respect the pixel budget)."""
    return {**STATE["meta"], "map_resolution": effective_ppd(roi, lat_ax)}


def _cache_key(kind: str, req: BaseModel) -> str:
    # Include the tile-set signature so adding/removing tiles invalidates old renders
    return cache.key(kind, {**req.model_dump(), "_ds": STATE["dataset"].signature})


_STEP_NUM = ("distance_km", "bearing_deg", "elevation_change_m", "max_slope_deg")
_STAT_NUM = ("distance_km", "straight_line_km", "eta_hours", "eta_sols", "energy_wh", "ascent_m",
             "descent_m", "mean_slope_deg", "max_slope_deg", "risk_score")


def _normalize_route_result(result: Dict[str, Any], start, end) -> None:
    """Make the JSON safe for strict typed clients (Dart `as num` casts crash on null).
    e.g. the final 'Arrive at destination' step used to have only distance_km."""
    for key, pt in (("start", start), ("end", end)):
        if not isinstance(result.get(key), dict):
            result[key] = {"lat": float(pt[0]), "lon": float(pt[1]), "moved_m": 0.0}
        result[key].setdefault("moved_m", 0.0)
    result.setdefault("warnings", [])
    for r in result.get("routes", []):
        r.setdefault("tags", [])
        stats = r.setdefault("stats", {})
        for k in _STAT_NUM:
            if stats.get(k) is None:
                stats[k] = 0.0
        stats.setdefault("difficulty", "Unknown")
        stats.setdefault("eta_label", "")
        prev_bearing = 0.0
        for st in r.get("steps", []):
            if st.get("bearing_deg") is not None:
                prev_bearing = st["bearing_deg"]
            for k in _STEP_NUM:
                if st.get(k) is None:
                    st[k] = prev_bearing if k == "bearing_deg" else 0.0
        for w in r.get("waypoints", []):
            for k in ("lat", "lon", "elev_m", "dist_km"):
                if w.get(k) is None:
                    w[k] = 0.0


def _image_meta(path: pathlib.Path, extent) -> Dict[str, Any]:
    """extent = (west, east, south, north). For map_only images, pixel (0,0) is the NW corner."""
    try:
        with Image.open(path) as im:
            size = [int(im.width), int(im.height)]
    except Exception:
        size = None
    return {"extent": [float(extent[0]), float(extent[1]), float(extent[2]), float(extent[3])],
            "image_size": size}


def _max_dim(v) -> int:
    return int(min(max(int(v or 6000), 800), 8000))


def _layer_ids(layers) -> List[str]:
    if not layers:
        return []
    if isinstance(layers, dict):
        return [k for k, v in layers.items() if v]
    return [str(x) for x in layers]


def _build_overlays(layer_ids, opacity_map, roi, lat_ax, lon_ax, extent):
    """Fetch/model every requested layer in parallel.
    Returns (overlays for the renderer, report for the UI, unavailable panels for the renderer)."""
    wanted = [l for l in LAYER_ORDER if l in set(layer_ids)]
    if not wanted:
        return [], [], []
    bbox = (extent[2], extent[3], extent[0], extent[1])          # south, north, west, east
    with ThreadPoolExecutor(max_workers=min(4, len(wanted))) as pool:
        results = list(pool.map(
            lambda l: LAYERS.get_overlay(l, bbox, roi.shape, roi, lat_ax, lon_ax), wanted))
    overlays, report, unavailable, seen = [], [], [], {}
    for lid, res in zip(wanted, results):
        name = LAYER_INFO[lid]["name"]
        entry = {k: res[k] for k in ("id", "ok", "provenance", "source", "note")}
        entry["legend"] = legend_for(lid, res["source"]) if res["ok"] else None
        report.append(entry)
        if not res["ok"] or res["rgba"] is None:
            unavailable.append({"title": name, "note": res["note"]})
            continue
        if res["provenance"] == "streamed" and res["source"] in seen:
            # e.g. HiRISE + CTX falling back to the same imagery: draw once, share one legend panel
            first = seen[res["source"]]
            first["title"] += f" / {name}"
            entry["note"] = (entry["note"] or "") + " Same imagery as another active layer; drawn once."
            continue
        ov = {
            "rgba": res["rgba"],
            "opacity": float((opacity_map or {}).get(lid, LAYER_INFO[lid]["default_opacity"])),
            "relief": lid in STREAMED_LAYERS,
            "title": name,
            "provenance": res["provenance"],
            "source": res["source"],
            "note": res["note"],
            "legend": entry["legend"],
        }
        if res["provenance"] == "streamed":
            seen[res["source"]] = ov
        overlays.append(ov)
    return overlays, report, unavailable


def _pick(body: RouteBody, *names):
    extra = body.model_extra or {}
    for n in names:
        v = getattr(body, n, None) if n in RouteBody.model_fields else extra.get(n)
        if v is not None:
            return v
    return None


def _as_latlon(v) -> Optional[Tuple[float, float]]:
    if v is None:
        return None
    if isinstance(v, dict):
        la = v.get("lat", v.get("latitude"))
        lo = v.get("lon", v.get("lng", v.get("longitude")))
        return (float(la), float(lo)) if la is not None and lo is not None else None
    if isinstance(v, (list, tuple)) and len(v) >= 2:
        return float(v[0]), float(v[1])
    return None


_PRIORITY_ALIASES = {
    "terrain_difficulty": "difficulty", "terrain": "difficulty", "difficulty": "difficulty",
    "safety": "safety", "science": "science", "distance": "distance", "energy": "energy",
}


def _norm_priorities(p: Optional[Dict[str, float]]) -> Dict[str, float]:
    out = {}
    for k, v in (p or {}).items():
        key = _PRIORITY_ALIASES.get(re.sub(r"[\s\-]+", "_", str(k).strip().lower()))
        if key and v is not None:
            out[key] = float(v)
    return out


def _resolve_route_points(body: RouteBody):
    s = (_as_latlon(body.start) or _as_latlon(_pick(body, "origin", "from")))
    e = (_as_latlon(body.end) or _as_latlon(_pick(body, "destination", "to")))
    if s is None:
        la, lo = _pick(body, "start_lat", "start_latitude", "startLat"), _pick(body, "start_lon", "start_longitude", "startLon", "start_lng")
        if la is not None and lo is not None:
            s = (float(la), float(lo))
    if e is None:
        la = _pick(body, "end_lat", "dest_lat", "destination_lat", "end_latitude", "destination_latitude", "endLat")
        lo = _pick(body, "end_lon", "dest_lon", "destination_lon", "end_longitude", "destination_longitude", "endLon", "end_lng")
        if la is not None and lo is not None:
            e = (float(la), float(lo))
    if s is None or e is None:
        raise HTTPException(422, detail="Provide a start and a destination (latitude and longitude for each).")
    return s, e


def _route_region(start, end, region: Optional[RegionBounds]):
    """(south, north, west, east). Uses the selected region if it contains both points,
    otherwise a padded box around the two points, clipped to the loaded MOLA extent."""
    m = STATE["meta"]
    inside = lambda r, p: r.south <= p[0] <= r.north and r.west <= p[1] <= r.east
    if region is not None and inside(region, start) and inside(region, end):
        return region.south, region.north, region.west, region.east, False
    lat_lo, lat_hi = sorted([start[0], end[0]])
    lon_lo, lon_hi = sorted([start[1], end[1]])
    pad_lat, pad_lon = max(1.5, 0.25 * (lat_hi - lat_lo)), max(1.5, 0.25 * (lon_hi - lon_lo))
    s = max(m["minimum_lat"], lat_lo - pad_lat)
    n = min(m["maximum_lat"], lat_hi + pad_lat)
    w = max(m["westernmost_lon"], lon_lo - pad_lon)
    e = min(m["easternmost_lon"], lon_hi + pad_lon)
    return s, n, w, e, region is not None


class Route3DBody(BaseModel):
    """Already-planned routes from the Flutter planner, to be drawn over 3D terrain."""
    model_config = ConfigDict(extra="allow")
    routes: List[Dict[str, Any]]                  # [{"label", "primary", "path": [[lat, lon], ...]}]
    region: Optional[RegionBounds] = None         # planning region (the response's `region`/`extent`)
    start: Optional[Any] = None
    end: Optional[Any] = None
    vertical_exaggeration: Optional[float] = 2.5
    title: Optional[str] = None


# --------------------------------------------------------------------------- #
# Startup / status
# --------------------------------------------------------------------------- #
@app.on_event("startup")
def startup():
    LAYERS.probe_async()             # warm the streaming health check in the background
    try:
        _ensure_loaded()
        ds, m = STATE["dataset"], STATE["meta"]
        print(f"[READY] {len(ds.tiles)} tile(s) loaded")
        for t in ds.tiles:
            print(f"        {t.name}: lat [{t.south}..{t.north}] lon [{t.west}..{t.east}] @ {t.ppd:g} ppd")
        for s in ds.skipped:
            print(f"[WARN]  skipped {s}")
        print(f"        Union extent: Lat [{m['minimum_lat']}..{m['maximum_lat']}] "
              f"Lon [{m['westernmost_lon']}..{m['easternmost_lon']}]")
    except Exception as e:
        traceback.print_exc()
        print(f"[WARN] Ingest pending: {getattr(e, 'detail', e)}")


@app.get("/api/status", response_model=StatusResponse)
def status():
    if STATE["dataset"] is None:
        try:
            _ensure_loaded()
        except Exception as e:
            return StatusResponse(
                status="no_data",
                message=str(getattr(e, "detail", e))
            )
    ds, m = STATE["dataset"], STATE["meta"]

    lat_pad = (m["maximum_lat"] - m["minimum_lat"]) * 0.15
    lon_pad = (m["easternmost_lon"] - m["westernmost_lon"]) * 0.15
    def_south = m["minimum_lat"] + lat_pad
    def_north = m["maximum_lat"] - lat_pad
    def_west = m["westernmost_lon"] + lon_pad
    def_east = m["easternmost_lon"] - lon_pad

    return StatusResponse(
        status="ready",
        dataset=f"{len(ds.tiles)} MOLA tile(s)" if len(ds.tiles) > 1 else ds.tiles[0].name,
        xml=None,
        resolution_ppd=m["map_resolution"],
        bounds={"south": m["minimum_lat"], "north": m["maximum_lat"],
                "west": m["westernmost_lon"], "east": m["easternmost_lon"]},
        shape=[int(m["lines"]), int(m["line_samples"])],
        message=f"Default:[{def_south:.1f},{def_north:.1f},{def_west:.1f},{def_east:.1f}]"
    )


@app.get("/api/tiles")
def tiles():
    """Debug: list every loaded tile and anything that was skipped."""
    _ensure_loaded()
    ds = STATE["dataset"]
    return {"signature": ds.signature, "tiles": ds.describe(), "skipped": ds.skipped}


@app.post("/api/reload")
def reload_data():
    """Rescan data/ after adding or removing tiles (no server restart needed)."""
    _ensure_loaded(force=True)
    ds = STATE["dataset"]
    return {"ok": True, "tiles": len(ds.tiles), "skipped": ds.skipped}


@app.get("/api/landmarks")
def landmarks():
    _ensure_loaded()
    ds = STATE["dataset"]
    res = []
    for k, v in LANDMARKS.items():
        lm_s, lm_n = v["lat"]
        lm_w, lm_e = v["lon"]
        cov = ds.coverage((lm_s, lm_n), (lm_w, lm_e))
        res.append({
            "name": k,
            "lat_min": lm_s,
            "lat_max": lm_n,
            "lon_min": lm_w,
            "lon_max": lm_e,
            "is_available": cov > 0.0,
            "coverage_pct": round(cov * 100.0, 1),
        })
    return res


@app.get("/api/layers")
def layers():
    """Real layer status. `connected` is None while the first health check is still running.
    `provenance`: "local" | "streamed" (live NASA/USGS imagery) | "modeled" (derived from MOLA)."""
    return LAYERS.status_all()


@app.post("/api/layers/refresh")
def layers_refresh():
    LAYERS.probe_async()
    return {"ok": True}


@app.post("/api/select-region")
def select_region(region: RegionBounds):
    _ensure_loaded()
    try:
        roi, lat_ax, lon_ax = crop_roi(
            STATE["dataset"], STATE["meta"],
            (region.south, region.north),
            (region.west, region.east),
            max_pixels=MAX_PIXELS_2D,
        )
        stats = compute_terrain_statistics(
            roi, _roi_meta(roi, lat_ax),
            (region.south, region.north),
            (region.west, region.east)
        )
        return {"ok": True, "statistics": stats}
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e))


# --------------------------------------------------------------------------- #
# Route planning  (this endpoint did not exist before -> the UI's "Not Found")
# --------------------------------------------------------------------------- #
@app.post("/api/route")
@app.post("/api/route/plan")
@app.post("/api/routes")
@app.post("/api/plan-route")
def route(body: RouteBody):
    _ensure_loaded()
    start, end = _resolve_route_points(body)
    pri = _norm_priorities(body.priorities or _pick(body, "weights", "mission_priorities"))

    m = STATE["meta"]
    for name, (la, lo) in (("Start", start), ("Destination", end)):
        if not (m["minimum_lat"] <= la <= m["maximum_lat"] and m["westernmost_lon"] <= lo <= m["easternmost_lon"]):
            raise HTTPException(422, detail=(
                f"{name} ({la:.2f}°N, {lo:.2f}°E) is outside the loaded MOLA data "
                f"[{m['minimum_lat']:.1f}..{m['maximum_lat']:.1f}°N, "
                f"{m['westernmost_lon']:.1f}..{m['easternmost_lon']:.1f}°E]."))

    s, n, w, e, region_replaced = _route_region(start, end, body.region)
    try:
        roi, lat_ax, lon_ax = crop_roi(STATE["dataset"], m, (s, n), (w, e), max_pixels=MAX_PIXELS_ROUTE)
    except Exception as ex:
        raise HTTPException(400, detail=f"Could not load terrain for this route: {ex}")

    # Science weight: heuristic proxy from modeled mineral diversity (labelled in the response)
    sci_map = None
    if pri.get("science", 0.0) > 0.0:
        sci_map = LAYERS.science_proxy(roi, lat_ax, lon_ax)

    try:
        result = plan_routes(roi, lat_ax, lon_ax, start, end, priorities=pri,
                             max_slope_deg=float(body.max_slope_deg), science_map=sci_map)
    except ValueError as ex:
        raise HTTPException(422, detail=str(ex))
    except Exception as ex:
        traceback.print_exc()
        raise HTTPException(500, detail=f"Route planning failed: {ex}")

    if not result.get("ok"):
        raise HTTPException(422, detail=result.get("error", "No route found."))

    _normalize_route_result(result, start, end)
    result["region"] = {"south": s, "north": n, "west": w, "east": e}
    if region_replaced:
        result.setdefault("warnings", []).append(
            "Selected region did not contain both points; planned over a box around start and destination.")
    if sci_map is not None:
        result.setdefault("assumptions", {})["science_note"] = (
            "Science weight uses a heuristic from modeled mineral diversity, not measured CRISM data.")

    if body.render:
        try:
            # the planning grid is small; draw the map from a more detailed crop so it zooms well
            try:
                map_roi, map_lat, map_lon = crop_roi(
                    STATE["dataset"], m, (s, n), (w, e),
                    max_pixels=MAX_PIXELS_2D if body.map_only else MAX_PIXELS_ROUTE_MAP)
            except Exception:
                map_roi, map_lat, map_lon = roi, lat_ax, lon_ax
            result.update(_render_route_map(body, result, map_roi, map_lat, map_lon, (w, e, s, n), start, end))
        except Exception as ex:
            traceback.print_exc()
            result.setdefault("warnings", []).append(f"Routes planned, but the map image failed: {ex}")
    return result


def _render_route_map(body, result, roi, lat_ax, lon_ax, extent, start, end):
    ids = _layer_ids(body.layers)
    overlays, report, unavailable = _build_overlays(ids, body.layer_opacity, roi, lat_ax, lon_ax, extent)

    draw_routes = []
    for r in result["routes"]:
        st = r["stats"]
        draw_routes.append({
            "path": r["path"],
            "primary": r["id"] == "recommended",
            "label": f"{r['label']} · {st['distance_km']:.0f} km · {st['eta_label']}",
        })
    markers = [{"kind": "start", "lat": start[0], "lon": start[1]},
               {"kind": "end", "lat": end[0], "lon": end[1]}]

    map_only = bool(body.map_only)
    sig = hashlib.sha1(json.dumps([start, end, extent, ids, map_only, body.max_dim,
                                   result["routes"][0]["stats"]],
                                  sort_keys=True, default=str).encode()).hexdigest()[:16]
    out = GEN_DIR / f"route2d_{sig}.png"
    legend = GEN_DIR / f"route2d_{sig}_legend.png"
    legend.unlink(missing_ok=True)
    render_2d_hillshade(roi, extent, effective_ppd(roi, lat_ax), str(out),
                        title=body.title or "Mars Route Plan",
                        overlays=overlays, routes=draw_routes, markers=markers, unavailable=unavailable,
                        map_only=map_only, max_dim=_max_dim(body.max_dim),
                        legend_path=str(legend) if map_only else None)
    resp = {"map_file": out.name, "map_url": f"/files/{out.name}", "layers_used": report,
            "legend_url": f"/files/{legend.name}" if legend.exists() else None,
            "map_only": map_only}
    resp.update(_image_meta(out, extent))
    return resp


# --------------------------------------------------------------------------- #
# Renders
# --------------------------------------------------------------------------- #
@app.post("/api/render/2d")
def render_2d(req: RenderRequestV2):
    _ensure_loaded()
    try:
        key = _cache_key("2d", req)
        extent = (req.region.west, req.region.east, req.region.south, req.region.north)
        legend = GEN_DIR / f"legend_{key}.png"
        cached = cache.lookup(key)
        if cached:
            cpath = pathlib.Path(cached)
            return {"ok": True, "file": cpath.name, "url": f"/files/{cpath.name}", "cached": True,
                    "layers_used": [], "map_only": bool(req.map_only),
                    "legend_url": f"/files/{legend.name}" if legend.exists() else None,
                    **_image_meta(GEN_DIR / cpath.name, extent)}

        roi, lat_ax, lon_ax = crop_roi(
            STATE["dataset"], STATE["meta"],
            (req.region.south, req.region.north),
            (req.region.west, req.region.east),
            max_pixels=MAX_PIXELS_2D,
        )

        overlays, report, unavailable = _build_overlays(_layer_ids(req.layers), req.layer_opacity,
                                                        roi, lat_ax, lon_ax, extent)
        out = GEN_DIR / f"render2d_{key}.png"
        legend.unlink(missing_ok=True)
        render_2d_hillshade(
            roi, extent, effective_ppd(roi, lat_ax), str(out),
            azimuth=req.azimuth or 315.0, altitude=req.altitude or 45.0,
            vert_exag=req.vertical_exaggeration or 2.5,
            title=req.title or "Mars Terrain",
            overlays=overlays, routes=req.routes, markers=req.markers, unavailable=unavailable,
            map_only=bool(req.map_only), max_dim=_max_dim(req.max_dim),
            legend_path=str(legend) if req.map_only else None,
        )
        hm = GEN_DIR / f"heightmap_{key}.png"
        export_heightmap_16bit(roi, str(hm))
        # Don't cache a render whose streamed layers failed, so a retry can succeed
        if all(r["ok"] for r in report):
            cache.store(key, str(out))
        return {"ok": True, "file": out.name, "url": f"/files/{out.name}",
                "heightmap": f"/files/{hm.name}", "cached": False, "layers_used": report,
                "map_only": bool(req.map_only),
                "legend_url": f"/files/{legend.name}" if legend.exists() else None,
                **_image_meta(out, extent)}
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    except Exception as e:
        traceback.print_exc()
        raise HTTPException(status_code=500, detail=f"2D Render internal failure: {e}")


@app.post("/api/render/3d")
def render_3d(req: RenderRequest):
    _ensure_loaded()
    try:
        key = _cache_key("3d", req)
        cached = cache.lookup(key)
        if cached:
            return {"ok": True, "file": pathlib.Path(cached).name,
                    "url": f"/files/{pathlib.Path(cached).name}", "cached": True}

        roi, lat_ax, lon_ax = crop_roi(
            STATE["dataset"], STATE["meta"],
            (req.region.south, req.region.north),
            (req.region.west, req.region.east),
            max_pixels=MAX_PIXELS_3D,
        )

        out = GEN_DIR / f"terrain3d_{key}.html"
        render_3d_plotly(
            roi, lat_ax, lon_ax,
            vert_exag=req.vertical_exaggeration or 2.5,
            output_html=str(out),
            title=req.title or "Mars Terrain"
        )
        cache.store(key, str(out))
        return {"ok": True, "file": out.name, "url": f"/files/{out.name}", "cached": False}
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    except Exception as e:
        traceback.print_exc()
        raise HTTPException(status_code=500, detail=f"3D Render internal failure: {e}")


@app.post("/api/render/route-3d")
def render_route_3d(body: Route3DBody):
    """3D terrain with the planned routes draped on it (reuses the plan-route output, no re-planning)."""
    _ensure_loaded()
    try:
        routes = []
        for i, r in enumerate(body.routes):
            path = [[float(p[0]), float(p[1])] for p in (r.get("path") or []) if isinstance(p, (list, tuple)) and len(p) >= 2]
            if len(path) >= 2:
                routes.append({"label": r.get("label") or f"Route {i + 1}",
                               "primary": bool(r.get("primary")), "path": path})
        if not routes:
            raise ValueError("No route geometry supplied. Plan a route first.")

        pts = [p for r in routes for p in r["path"]]
        start = _as_latlon(body.start) or tuple(routes[0]["path"][0])
        end = _as_latlon(body.end) or tuple(routes[0]["path"][-1])
        if body.region is not None:
            s, n, w, e = body.region.south, body.region.north, body.region.west, body.region.east
        else:
            lats, lons = [p[0] for p in pts], [p[1] for p in pts]
            pad_lat = max(0.5, 0.1 * (max(lats) - min(lats)))
            pad_lon = max(0.5, 0.1 * (max(lons) - min(lons)))
            s, n, w, e = min(lats) - pad_lat, max(lats) + pad_lat, min(lons) - pad_lon, max(lons) + pad_lon
        vexag = float(body.vertical_exaggeration or 2.5)

        sig = hashlib.sha1(json.dumps([routes, [s, n, w, e], vexag, STATE["dataset"].signature],
                                      sort_keys=True, default=str).encode()).hexdigest()[:16]
        out = GEN_DIR / f"route3d_{sig}.html"
        if not out.exists():
            roi, lat_ax, lon_ax = crop_roi(STATE["dataset"], STATE["meta"], (s, n), (w, e),
                                           max_pixels=MAX_PIXELS_3D)
            render_3d_plotly(
                roi, lat_ax, lon_ax, vert_exag=vexag, output_html=str(out),
                title=body.title or "Mars Route Plan",
                routes=routes,
                markers=[{"kind": "start", "lat": start[0], "lon": start[1]},
                         {"kind": "end", "lat": end[0], "lon": end[1]}],
            )
        return {"ok": True, "file": out.name, "url": f"/files/{out.name}",
                "region": {"south": s, "north": n, "west": w, "east": e}}
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    except HTTPException:
        raise
    except Exception as e:
        traceback.print_exc()
        raise HTTPException(status_code=500, detail=f"3D route render failure: {e}")


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="127.0.0.1", port=8000)