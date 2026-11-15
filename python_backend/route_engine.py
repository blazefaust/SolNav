"""
route_engine.py — Rover route planning over MOLA terrain (Google-Maps style).

Builds a traversal cost surface from slope + hazard fraction (+ optional
science value), runs A* (8-connected, uphill-aware) and returns several
alternatives: Recommended (your priorities), Shortest, Safest, Energy saver.

Each route has: geometry, simplified waypoints, turn-by-turn steps, elevation
profile and stats (distance, ETA, energy, slope, ascent/descent, risk).

Limits (be honest in the UI): slope comes from 128-ppd-class MOLA (~460 m/px at
best), so this plans at *regional* scale. Boulders and small hazards are not
resolved; use HiRISE-scale data for final driving.
"""
import heapq
import math
from typing import Any, Dict, List, Optional, Tuple

import numpy as np

METERS_PER_DEG = 59150.0
MARS_G = 3.721
SOL_S = 88775.244
ROVER = {"mass_kg": 1025.0, "speed_mps": 0.04, "rolling": 0.2, "eff": 0.3}
RISK_REF_SLOPE_DEG = 25.0


# --------------------------------------------------------------------------- #
# Back-compat shim for the old placeholder API
# --------------------------------------------------------------------------- #
class RouteRequest:
    def __init__(self, start, end, priorities):
        self.start: Tuple[float, float] = start
        self.end: Tuple[float, float] = end
        self.priorities: Dict[str, float] = priorities


# --------------------------------------------------------------------------- #
# Grid construction
# --------------------------------------------------------------------------- #
def _block_mean(a: np.ndarray, step: int) -> np.ndarray:
    if step <= 1:
        return a.astype(np.float32)
    r, c = (a.shape[0] // step) * step, (a.shape[1] // step) * step
    blk = a[:r, :c].reshape(r // step, step, c // step, step).astype(np.float32)
    valid = ~np.isnan(blk)
    cnt = valid.sum(axis=(1, 3))
    tot = np.where(valid, blk, 0.0).sum(axis=(1, 3))
    return np.where(cnt > 0, tot / np.maximum(cnt, 1), np.nan).astype(np.float32)


def _block_axis(ax: np.ndarray, step: int) -> np.ndarray:
    if step <= 1:
        return np.asarray(ax, dtype=np.float64)
    n = (len(ax) // step) * step
    return np.asarray(ax[:n], dtype=np.float64).reshape(-1, step).mean(axis=1)


class _Grid:
    pass


def _build_grid(roi, lat_ax, lon_ax, max_grid, science_map=None) -> _Grid:
    roi = np.asarray(roi, dtype=np.float32)
    rows0, cols0 = roi.shape
    dlat = abs(float(lat_ax[0] - lat_ax[-1])) / max(rows0 - 1, 1)
    dlon = abs(float(lon_ax[-1] - lon_ax[0])) / max(cols0 - 1, 1)
    cos_lat = max(0.05, math.cos(math.radians(float(np.mean(lat_ax)))))
    dy0, dx0 = dlat * METERS_PER_DEG, dlon * METERS_PER_DEG * cos_lat

    valid0 = ~np.isnan(roi)
    if not valid0.any():
        raise ValueError("No valid elevation samples in region.")
    clean = np.where(valid0, roi, float(np.nanmean(roi)))
    gy, gx = np.gradient(clean, dy0, dx0)
    slope0 = np.degrees(np.arctan(np.hypot(gx, gy))).astype(np.float32)

    step = int(math.ceil(max(rows0, cols0) / float(max_grid)))
    g = _Grid()
    g.step = step
    g.slope0 = slope0
    z = _block_mean(roi, step)
    g.rows, g.cols = z.shape
    g.valid = (~np.isnan(z)) & (_block_mean(valid0.astype(np.float32), step) >= 0.5)
    g.z = np.where(np.isnan(z), float(np.nanmean(z)), z)
    g.slope = _block_mean(slope0, step)
    g.la = _block_axis(lat_ax, step)
    g.lo = _block_axis(lon_ax, step)
    g.dy, g.dx = dy0 * step, dx0 * step
    g.cell_m = float(0.5 * (g.dy + g.dx))
    g.steep_cache = {}
    g.science = None
    if science_map is not None:
        sm = np.asarray(science_map, dtype=np.float32)
        ri = np.clip((np.arange(g.rows) * sm.shape[0] / g.rows).astype(int), 0, sm.shape[0] - 1)
        ci = np.clip((np.arange(g.cols) * sm.shape[1] / g.cols).astype(int), 0, sm.shape[1] - 1)
        g.science = np.clip(np.nan_to_num(sm[np.ix_(ri, ci)]), 0.0, 1.0)
    return g


def _steep_fraction(g: _Grid, limit: float) -> np.ndarray:
    key = round(float(limit), 1)
    if key not in g.steep_cache:
        g.steep_cache[key] = _block_mean((g.slope0 > limit).astype(np.float32), g.step)
        g.steep_cache[key] = np.nan_to_num(g.steep_cache[key])
    return g.steep_cache[key]


def _to_cell(g: _Grid, lat: float, lon: float) -> Tuple[int, int]:
    r = (lat - g.la[0]) / (g.la[-1] - g.la[0]) * (g.rows - 1) if g.rows > 1 else 0
    c = (lon - g.lo[0]) / (g.lo[-1] - g.lo[0]) * (g.cols - 1) if g.cols > 1 else 0
    return int(np.clip(round(r), 0, g.rows - 1)), int(np.clip(round(c), 0, g.cols - 1))


def _cell_latlon(g: _Grid, r: float, c: float) -> Tuple[float, float]:
    lat = g.la[0] + (g.la[-1] - g.la[0]) * (r / max(g.rows - 1, 1))
    lon = g.lo[0] + (g.lo[-1] - g.lo[0]) * (c / max(g.cols - 1, 1))
    return float(lat), float(lon)


# --------------------------------------------------------------------------- #
# Profiles / weights
# --------------------------------------------------------------------------- #
def _priority_weights(p: Optional[Dict[str, float]]) -> Dict[str, float]:
    d = {"safety": 0.5, "science": 0.0, "distance": 0.5, "energy": 0.3, "difficulty": 0.3}
    for k in list(d):
        if p and p.get(k) is not None:
            try:
                d[k] = float(p[k])
            except (TypeError, ValueError):
                pass
    m = max(max(d.values()), 1e-9)
    if m > 1.0:
        d = {k: v / m for k, v in d.items()}
    return {k: float(np.clip(v, 0.0, 1.0)) for k, v in d.items()}


def _profiles(pri: Dict[str, float], max_slope: float) -> List[Dict[str, Any]]:
    s, dist, en, sci, diff = pri["safety"], pri["distance"], pri["energy"], pri["science"], pri["difficulty"]
    return [
        {"key": "recommended", "label": "Recommended",
         "w_len": 0.2 + 1.6 * dist,                 # Distance slider: cost of every metre driven (0.5 -> 1.0)
         "w_slope": 0.3 + 3.0 * s, "w_haz": 0.3 + 3.0 * diff,
         "w_rough": diff,                           # Terrain-difficulty slider: avoid moderately rough ground
         "w_energy": 2.0 * en, "w_sci": sci,
         "limit": max(8.0, max_slope - 7.0 * s), "haz_cap": 0.35 - 0.15 * s},
        {"key": "shortest", "label": "Shortest",
         "w_slope": 0.25, "w_haz": 0.25, "w_energy": 0.0, "w_sci": 0.0,
         "limit": max_slope, "haz_cap": 0.45},
        {"key": "safest", "label": "Safest",
         "w_slope": 3.5, "w_haz": 3.5, "w_energy": 0.5, "w_sci": 0.0,
         "limit": min(max_slope, 16.0), "haz_cap": 0.15},
        {"key": "energy", "label": "Energy saver",
         "w_slope": 1.0, "w_haz": 0.8, "w_energy": 2.5, "w_sci": 0.0,
         "limit": max_slope, "haz_cap": 0.35},
    ]


def _cost_arrays(g: _Grid, prof: Dict[str, Any], relaxed: bool = False):
    limit = prof["limit"] + (8.0 if relaxed else 0.0)
    haz_cap = prof["haz_cap"] + (0.2 if relaxed else 0.0)
    steep = _steep_fraction(g, limit * 0.8)
    sn = np.clip(g.slope / limit, 0.0, 1.5)
    f = prof.get("w_len", 1.0) + prof["w_slope"] * 6.0 * sn ** 2 + prof["w_haz"] * 4.0 * steep
    if prof.get("w_rough", 0.0) > 0:
        # Terrain difficulty: penalise cells where many sub-pixels are moderately steep (> ~25% of the limit)
        f = f + prof["w_rough"] * 3.0 * _steep_fraction(g, limit * 0.25)
    if g.science is not None and prof["w_sci"] > 0:
        f = f * np.clip(1.0 - 0.6 * prof["w_sci"] * g.science, 0.35, 1.0)
    passable = g.valid & (g.slope <= limit) & (steep <= haz_cap)
    return f.astype(np.float64), passable


# --------------------------------------------------------------------------- #
# A*
# --------------------------------------------------------------------------- #
def _astar(f, passable, z, rows, cols, dy, dx, w_energy, s_idx, g_idx):
    N = rows * cols
    INF = float("inf")
    gs = [INF] * N
    parent = [-1] * N
    ff = f.ravel().tolist()
    pp = passable.ravel().tolist()
    zz = z.ravel().tolist()
    fmin = float(f[passable].min()) if passable.any() else 1.0
    nbrs = [(dr, dc, math.hypot(dr * dy, dc * dx)) for dr in (-1, 0, 1) for dc in (-1, 0, 1) if (dr, dc) != (0, 0)]
    gr, gc = divmod(g_idx, cols)
    hypot = math.hypot
    push, pop = heapq.heappush, heapq.heappop

    sr, sc = divmod(s_idx, cols)
    gs[s_idx] = 0.0
    heap = [(hypot((sr - gr) * dy, (sc - gc) * dx) * fmin, 0.0, s_idx)]
    while heap:
        _, gcur, u = pop(heap)
        if gcur > gs[u]:
            continue
        if u == g_idx:
            break
        r, c = divmod(u, cols)
        fu, zu = ff[u], zz[u]
        for dr, dc, d in nbrs:
            nr, nc = r + dr, c + dc
            if nr < 0 or nr >= rows or nc < 0 or nc >= cols:
                continue
            v = u + dr * cols + dc
            if not pp[v]:
                continue
            if dr and dc and not (pp[u + dr * cols] and pp[u + dc]):
                continue                      # no squeezing diagonally between blocked cells
            cost = d * 0.5 * (fu + ff[v])
            dz = zz[v] - zu
            if dz > 0.0:
                cost += w_energy * 5.0 * dz   # 1 m of climb ~ 5 m of flat driving
            ng = gcur + cost
            if ng < gs[v]:
                gs[v] = ng
                parent[v] = u
                push(heap, (ng + hypot((nr - gr) * dy, (nc - gc) * dx) * fmin, ng, v))
    if gs[g_idx] == INF:
        return None
    path, cur = [], g_idx
    while cur != -1:
        path.append(cur)
        cur = parent[cur]
    return path[::-1]


def _snap(passable: np.ndarray, rc: Tuple[int, int]) -> Optional[Tuple[int, int]]:
    if passable[rc]:
        return rc
    ys, xs = np.nonzero(passable)
    if ys.size == 0:
        return None
    k = int(np.argmin((ys - rc[0]) ** 2 + (xs - rc[1]) ** 2))
    return int(ys[k]), int(xs[k])


# --------------------------------------------------------------------------- #
# Route post-processing
# --------------------------------------------------------------------------- #
def _rdp(xy: np.ndarray, tol: float) -> List[int]:
    n = len(xy)
    if n <= 2:
        return list(range(n))
    keep = np.zeros(n, dtype=bool)
    keep[0] = keep[-1] = True
    stack = [(0, n - 1)]
    while stack:
        a, b = stack.pop()
        if b <= a + 1:
            continue
        p, q = xy[a], xy[b]
        seg = q - p
        L = float(np.hypot(*seg))
        pts = xy[a + 1:b] - p
        d = np.abs(pts[:, 0] * seg[1] - pts[:, 1] * seg[0]) / L if L > 0 else np.hypot(pts[:, 0], pts[:, 1])
        i = int(np.argmax(d))
        if d[i] > tol:
            k = a + 1 + i
            keep[k] = True
            stack += [(a, k), (k, b)]
    return list(np.nonzero(keep)[0])


def _eta_label(hours: float) -> str:
    if hours < 1:
        return f"{hours * 60:.0f} min"
    if hours < 24:
        return f"{hours:.1f} h"
    return f"{hours * 3600 / SOL_S:.1f} sols"


def _bearing(dlat_m: float, dlon_m: float) -> float:
    return (math.degrees(math.atan2(dlon_m, dlat_m)) + 360.0) % 360.0


def _compass(b: float) -> str:
    return ["N", "NE", "E", "SE", "S", "SW", "W", "NW"][int(((b % 360) + 22.5) // 45) % 8]


def _describe(g: _Grid, idx_path: List[int], prof: Dict[str, Any], rover: Dict[str, float]) -> Dict[str, Any]:
    rc = np.array([divmod(i, g.cols) for i in idx_path], dtype=np.float64)
    r, c = rc[:, 0].astype(int), rc[:, 1].astype(int)
    z = g.z[r, c].astype(np.float64)
    slope = g.slope[r, c].astype(np.float64)

    horiz = np.hypot(np.diff(rc[:, 0]) * g.dy, np.diff(rc[:, 1]) * g.dx)
    dz = np.diff(z)
    d3 = np.hypot(horiz, dz)
    seg_slope = 0.5 * (slope[:-1] + slope[1:])
    cum = np.concatenate([[0.0], np.cumsum(d3)])

    v = rover["speed_mps"] * np.maximum(0.35, 1.0 - seg_slope / 40.0)
    hours = float(np.sum(d3 / v) / 3600.0)
    m, gm = rover["mass_kg"], MARS_G
    energy_wh = float(np.sum(rover["rolling"] * m * gm * d3 + m * gm * np.maximum(dz, 0.0)) / rover["eff"] / 3600.0)
    mean_s, max_s = float(slope.mean()), float(slope.max())
    risk = float(np.clip(100.0 * (0.5 * mean_s + 0.5 * max_s) / RISK_REF_SLOPE_DEG, 0, 100))
    difficulty = "Easy" if risk < 25 else "Moderate" if risk < 50 else "Challenging" if risk < 75 else "Extreme"

    lat = g.la[0] + (g.la[-1] - g.la[0]) * (rc[:, 0] / max(g.rows - 1, 1))
    lon = g.lo[0] + (g.lo[-1] - g.lo[0]) * (rc[:, 1] / max(g.cols - 1, 1))
    cos_lat = max(0.05, math.cos(math.radians(float(lat.mean()))))
    xy = np.column_stack([(lon - lon[0]) * METERS_PER_DEG * cos_lat, (lat - lat[0]) * METERS_PER_DEG])

    # waypoints + turn-by-turn
    keep = _rdp(xy, tol=1.5 * max(g.dx, g.dy))
    waypoints = [{"lat": float(lat[i]), "lon": float(lon[i]), "elev_m": float(z[i]),
                  "dist_km": float(cum[i] / 1000.0)} for i in keep]
    steps, prev_b = [], None
    for a, b in zip(keep[:-1], keep[1:]):
        bear = _bearing((lat[b] - lat[a]) * METERS_PER_DEG, (lon[b] - lon[a]) * METERS_PER_DEG * cos_lat)
        leg_km = float((cum[b] - cum[a]) / 1000.0)
        leg_dz = float(z[b] - z[a])
        if prev_b is None:
            text = f"Head {_compass(bear)}"
        else:
            turn = ((bear - prev_b + 540.0) % 360.0) - 180.0
            text = (f"Continue {_compass(bear)}" if abs(turn) < 20
                    else f"Turn {'right' if turn > 0 else 'left'} toward {_compass(bear)}")
        steps.append({"instruction": f"{text} for {leg_km:.1f} km", "distance_km": round(leg_km, 2),
                      "bearing_deg": round(bear, 0), "elevation_change_m": round(leg_dz, 0),
                      "max_slope_deg": round(float(slope[a:b + 1].max()), 1)})
        prev_b = bear
    steps.append({"instruction": "Arrive at destination", "distance_km": 0.0})

    # downsampled outputs for the UI
    def thin(n_max):
        return np.unique(np.linspace(0, len(idx_path) - 1, min(n_max, len(idx_path))).astype(int))
    p_i, pr_i = thin(500), thin(150)
    stats = {
        "distance_km": round(float(cum[-1] / 1000.0), 2),
        "straight_line_km": round(float(np.hypot(*xy[-1]) / 1000.0), 2),
        "eta_hours": round(hours, 1), "eta_sols": round(hours * 3600.0 / SOL_S, 2), "eta_label": _eta_label(hours),
        "energy_wh": round(energy_wh, 0),
        "ascent_m": round(float(np.maximum(dz, 0).sum()), 0), "descent_m": round(float(np.maximum(-dz, 0).sum()), 0),
        "mean_slope_deg": round(mean_s, 1), "max_slope_deg": round(max_s, 1),
        "risk_score": round(risk, 0), "difficulty": difficulty,
    }
    return {
        "path": [[float(lat[i]), float(lon[i])] for i in p_i],
        "waypoints": waypoints, "steps": steps, "stats": stats,
        "profile": {"dist_km": [round(float(cum[i] / 1000.0), 3) for i in pr_i],
                    "elev_m": [round(float(z[i]), 1) for i in pr_i],
                    "slope_deg": [round(float(slope[i]), 1) for i in pr_i]},
        "_cells": set(idx_path),
    }


# --------------------------------------------------------------------------- #
# Public API
# --------------------------------------------------------------------------- #
def plan_routes(roi: np.ndarray, lat_axis: np.ndarray, lon_axis: np.ndarray,
                start: Tuple[float, float], end: Tuple[float, float],
                priorities: Optional[Dict[str, float]] = None, max_slope_deg: float = 25.0,
                science_map: Optional[np.ndarray] = None, max_grid: int = 240,
                rover: Optional[Dict[str, float]] = None) -> Dict[str, Any]:
    rover = {**ROVER, **(rover or {})}
    warnings: List[str] = []

    lat_lo, lat_hi = float(min(lat_axis[0], lat_axis[-1])), float(max(lat_axis[0], lat_axis[-1]))
    lon_lo, lon_hi = float(lon_axis[0]), float(lon_axis[-1])
    for name, (la, lo) in (("Start", start), ("Destination", end)):
        if not (lat_lo <= la <= lat_hi and lon_lo <= lo <= lon_hi):
            return {"ok": False, "error": f"{name} ({la:.2f}°N, {lo:.2f}°E) is outside the selected region "
                                          f"[{lat_lo:.1f}..{lat_hi:.1f}°N, {lon_lo:.1f}..{lon_hi:.1f}°E]."}

    g = _build_grid(roi, lat_axis, lon_axis, max_grid, science_map)
    if g.cell_m > 2000:
        warnings.append(f"Planning cell size is {g.cell_m / 1000:.1f} km: region is large, so routes are indicative only. "
                        f"Select a smaller area for rover-scale planning.")

    s_rc0, e_rc0 = _to_cell(g, *start), _to_cell(g, *end)
    pri = _priority_weights(priorities)
    if pri["science"] > 0 and g.science is None:
        warnings.append("Science priority has no effect: no science layer was supplied to the planner.")
    routes: List[Dict[str, Any]] = []
    snapped_info: Dict[str, Any] = {}

    rec_prof: Dict[str, Any] = {}
    for prof in _profiles(pri, float(max_slope_deg)):
        if prof["key"] == "recommended":
            rec_prof = {k: round(v, 2) for k, v in prof.items() if isinstance(v, float)}
        path, used_relaxed = None, False
        for relaxed in (False, True):
            f, passable = _cost_arrays(g, prof, relaxed)
            s_rc, e_rc = _snap(passable, s_rc0), _snap(passable, e_rc0)
            if s_rc is None or e_rc is None:
                continue
            path = _astar(f, passable, g.z, g.rows, g.cols, g.dy, g.dx, prof["w_energy"],
                          s_rc[0] * g.cols + s_rc[1], e_rc[0] * g.cols + e_rc[1])
            if path:
                used_relaxed = relaxed
                break
        if not path:
            if prof["key"] == "recommended":
                return {"ok": False, "error": "No drivable route found: start and destination are separated by terrain "
                                              f"steeper than {max_slope_deg + 8:.0f}°. Pick different points or raise max slope.",
                        "warnings": warnings}
            warnings.append(f"No '{prof['label']}' route found.")
            continue

        d = _describe(g, path, prof, rover)
        d.update(id=prof["key"], label=prof["label"], tags=[])
        if used_relaxed:
            d["stats"]["note"] = f"Needed relaxed slope limit (+8°)"
        if prof["key"] == "recommended":
            for key, rc0, rc1 in (("start", s_rc0, s_rc), ("end", e_rc0, e_rc)):
                moved = math.hypot((rc0[0] - rc1[0]) * g.dy, (rc0[1] - rc1[1]) * g.dx)
                lat_s, lon_s = _cell_latlon(g, *rc1)
                snapped_info[key] = {"lat": lat_s, "lon": lon_s, "moved_m": round(moved, 0)}
                if moved > 1.5 * g.cell_m:
                    warnings.append(f"{key.capitalize()} point was on impassable terrain; moved {moved / 1000:.1f} km to the nearest drivable cell.")

        # de-duplicate near-identical alternatives
        dup = None
        for kept in routes:
            inter = len(d["_cells"] & kept["_cells"])
            if inter / max(len(d["_cells"] | kept["_cells"]), 1) > 0.9:
                dup = kept
                break
        if dup:
            dup["tags"].append(f"Also {prof['label'].lower()}")
        else:
            routes.append(d)

    # Google-Maps-style badges
    fastest = min(routes, key=lambda r: r["stats"]["eta_hours"])
    safest = min(routes, key=lambda r: r["stats"]["risk_score"])
    eff = min(routes, key=lambda r: r["stats"]["energy_wh"])
    fastest["tags"].append("Fastest")
    if safest is not fastest or len(routes) == 1:
        safest["tags"].append("Lowest risk")
    if eff is not fastest and eff is not safest:
        eff["tags"].append("Lowest energy")
    for r in routes:
        r.pop("_cells", None)

    return {"ok": True, "routes": routes, "warnings": warnings, "start": snapped_info.get("start"),
            "end": snapped_info.get("end"),
            "grid": {"shape": [g.rows, g.cols], "cell_m": round(g.cell_m, 0)},
            "priorities": pri, "assumptions": {
                "rover": rover, "max_slope_deg": max_slope_deg, "recommended_profile": rec_prof,
                "note": "Energy/ETA are rough estimates from slope and distance only."}}