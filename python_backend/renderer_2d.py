"""renderer_2d.py — High-detail MOLA hillshade renderer with NASA layer overlays, routes and legends"""
import matplotlib
matplotlib.use("Agg")

import math
import textwrap

import numpy as np
import matplotlib.pyplot as plt
import matplotlib.colors as mcolors
import matplotlib.patheffects as pe
from matplotlib.colors import LightSource
from matplotlib.patches import Rectangle
from PIL import Image

MARS_COLORS = [
    "#080301","#1c0b04","#361508","#54220c","#733011","#913f17","#ae4f1d",
    "#c66124","#d9762d","#e68d3a","#efa54c","#f5bc62","#f9d17d","#fce39d",
    "#fef1bd","#f6e3c5","#e2cfbf","#f0eae1","#ffffff",
]
MARS_POSITIONS = [0.00,0.05,0.10,0.16,0.22,0.28,0.35,0.42,0.50,
                  0.58,0.65,0.72,0.78,0.84,0.89,0.93,0.96,0.98,1.00]
MARS_CMAP = mcolors.LinearSegmentedColormap.from_list(
    "mars_insane_detail", list(zip(MARS_POSITIONS, MARS_COLORS)), N=1024)
MARS_CMAP.set_bad(color="black")

ROUTE_PRIMARY = "#00E5FF"
ROUTE_ALT = "#CFD8DC"


class PiecewiseElevationNorm(mcolors.Normalize):
    def __init__(self, anchors, clip=False):
        self.anchors = sorted(anchors, key=lambda a: a[0])
        super().__init__(vmin=self.anchors[0][0], vmax=self.anchors[-1][0], clip=clip)

    def __call__(self, value, clip=None):
        xs = [a[0] for a in self.anchors]
        ys = [a[1] for a in self.anchors]
        arr = np.asarray(value, dtype=np.float64)
        flat = arr.ravel()
        valid = ~np.isnan(flat)
        out = np.empty_like(flat)
        out[valid] = np.interp(flat[valid], xs, ys)
        out[~valid] = np.nan
        return np.ma.masked_invalid(out.reshape(arr.shape))

    def inverse(self, value):
        xs = [a[0] for a in self.anchors]
        ys = [a[1] for a in self.anchors]
        return np.interp(value, ys, xs)


def build_mars_norm(data):
    valid = data[~np.isnan(data)]
    if valid.size == 0:
        return PiecewiseElevationNorm([(-1, 0.0), (1, 1.0)])
    p = lambda q: float(np.percentile(valid, q))
    anchors = [(p(0),0.0),(p(2),0.08),(p(15),0.22),(p(35),0.38),(p(60),0.54),
               (p(82),0.70),(p(93),0.82),(p(97.5),0.90),(p(99.5),0.96),(p(100),1.0)]
    out = [anchors[0]]
    for a in anchors[1:]:
        if a[0] <= out[-1][0]:
            a = (out[-1][0] + 1e-3, a[1])
        out.append(a)
    return PiecewiseElevationNorm(out)


# --------------------------------------------------------------------------- #
# Layer compositing + route drawing
# --------------------------------------------------------------------------- #
def _composite_overlays(rgb, hillshade, overlays, shape):
    """Alpha-composite NASA layers over the hillshaded elevation colours.
    Imagery layers ('relief': True) are lightly modulated by the hillshade so terrain still reads."""
    out = rgb
    for ov in overlays or []:
        rgba = np.asarray(ov["rgba"], dtype=np.float32)
        if rgba.shape[:2] != shape:
            rgba = np.asarray(Image.fromarray((rgba * 255).astype(np.uint8)).resize(
                (shape[1], shape[0]), Image.BILINEAR), dtype=np.float32) / 255.0
        a = rgba[..., 3:4] * float(np.clip(ov.get("opacity", 0.8), 0.0, 1.0))
        col = rgba[..., :3]
        if ov.get("relief"):
            col = np.clip(col * (0.65 + 0.35 * hillshade[..., None]), 0, 1)
        out = out * (1.0 - a) + col * a
    return out


def _route_style(rt):
    primary = bool(rt.get("primary"))
    return primary, (rt.get("color") or (ROUTE_PRIMARY if primary else ROUTE_ALT))


def _draw_routes(ax, routes, markers, scale=1.0):
    """scale > 1 thickens lines/markers for very large (zoomable) images."""
    outline = [pe.Stroke(linewidth=7 * scale, foreground="white", alpha=0.9), pe.Normal()]
    # alternates first so the primary route is on top
    for rt in sorted(routes or [], key=lambda r: bool(r.get("primary"))):
        pts = np.asarray(rt["path"], dtype=float)
        if len(pts) < 2:
            continue
        primary, color = _route_style(rt)
        ax.plot(pts[:, 1], pts[:, 0], color=color, lw=(4.0 if primary else 3.0) * scale,
                ls="-" if primary else (0, (5, 3)), zorder=6 if primary else 5,
                solid_capstyle="round", path_effects=outline if primary else
                [pe.Stroke(linewidth=5 * scale, foreground="black", alpha=0.55), pe.Normal()])
    for mk in markers or []:
        is_start = mk.get("kind") == "start"
        face = "#2ECC71" if is_start else "#FF3B30"
        ax.scatter([mk["lon"]], [mk["lat"]], s=330 * scale ** 2, c=face, edgecolors="white",
                   linewidths=2.2 * scale, zorder=9)
        ax.text(mk["lon"], mk["lat"], "A" if is_start else "B", color="white", fontsize=10 * scale,
                fontweight="bold", ha="center", va="center", zorder=10)


# --------------------------------------------------------------------------- #
# Legend panels (one per layer, plus routes)
# --------------------------------------------------------------------------- #
PANEL_H_IN = 3.0
PANEL_COLS = 3
BG, EDGE = "#10141c", "#444444"
BADGE = {"streamed": ("LIVE STREAM", "#2ECC71"), "modeled": ("MODELED", "#F5A623")}


def _gradient_rgb(stops, n=256):
    pos = [st["pos"] for st in stops]
    cols = np.array([mcolors.to_rgb(st["color"]) for st in stops])
    x = np.linspace(0.0, 1.0, n)
    return np.stack([np.interp(x, pos, cols[:, i]) for i in range(3)], axis=-1)[None]


def _panel_frame(ax, title, badge=None):
    ax.set_xlim(0, 1)
    ax.set_ylim(0, 1)
    ax.set_xticks([])
    ax.set_yticks([])
    ax.set_facecolor(BG)
    for sp in ax.spines.values():
        sp.set_color(EDGE)
    ax.text(0.04, 0.90, title, color="white", fontsize=10, fontweight="bold", ha="left", va="center")
    if badge:
        label, color = badge
        ax.text(0.97, 0.90, label, color="#0b0f14", fontsize=7, fontweight="bold", ha="right", va="center",
                bbox=dict(boxstyle="round,pad=0.25", fc=color, ec="none"))


def _wrap(text, width):
    return "\n".join(textwrap.fill(line, width) for line in str(text).split("\n"))


def _draw_layer_panel(ax, ov):
    lg = ov.get("legend") or {}
    _panel_frame(ax, ov.get("title") or "Layer", BADGE.get(ov.get("provenance")))
    if lg.get("type") == "gradient":
        stops = lg["stops"]
        ax.text(0.04, 0.82, lg.get("title", ""), color="#dddddd", fontsize=8, ha="left", va="center")
        g = ax.inset_axes([0.06, 0.57, 0.88, 0.13])
        g.imshow(_gradient_rgb(stops), aspect="auto", extent=(0, 1, 0, 1))
        g.set_xticks([])
        g.set_yticks([])
        for sp in g.spines.values():
            sp.set_color("#888888")
        for st in stops:
            x = 0.06 + 0.88 * st["pos"]
            ha = "left" if st["pos"] <= 0.0 else "right" if st["pos"] >= 1.0 else "center"
            ax.text(x, 0.535, st.get("label", ""), color="white", fontsize=8, ha=ha, va="top", linespacing=1.15)
    elif lg.get("type") == "categories":
        ax.text(0.04, 0.82, lg.get("title", ""), color="#dddddd", fontsize=8, ha="left", va="center")
        y = 0.72
        for it in lg["items"]:
            ax.add_patch(Rectangle((0.05, y - 0.045), 0.06, 0.09, fc=it["color"], ec="white", lw=0.6))
            ax.text(0.14, y, _wrap(it["label"], 52), color="white", fontsize=7.8, ha="left", va="center",
                    linespacing=1.1)
            y -= 0.12
    if lg.get("caption"):
        two_line_ticks = lg.get("type") == "gradient" and any("\n" in st.get("label", "") for st in lg["stops"])
        cap_y = 0.265 if lg.get("type") == "categories" else (0.37 if two_line_ticks else 0.43)
        ax.text(0.04, cap_y, _wrap(lg["caption"], 62), color="#bbbbbb", fontsize=7.8, ha="left", va="top",
                style="italic", linespacing=1.15)
    if ov.get("provenance") == "streamed":
        foot = f"Source: {ov.get('source') or 'n/a'}"
    else:
        foot = "Modeled from MOLA elevation, not measured data"
    foot += f"  |  opacity {int(round(100 * float(ov.get('opacity', 0.8))))}%"
    if ov.get("note") and ov.get("provenance") == "streamed":     # e.g. "showing fallback imagery"
        foot += "\n" + ov["note"]
    ax.text(0.04, 0.03, _wrap(foot, 78), color="#8a8f99", fontsize=6.8, ha="left", va="bottom", linespacing=1.1)


def _draw_unavailable_panel(ax, item):
    _panel_frame(ax, item.get("title") or "Layer", ("NOT DRAWN", "#FF5A4F"))
    ax.text(0.04, 0.70, _wrap(item.get("note") or "This layer could not be produced.", 60),
            color="white", fontsize=8.5, ha="left", va="top", linespacing=1.2)


def _draw_route_panel(ax, routes, markers):
    _panel_frame(ax, "Routes")
    y = 0.78
    for rt in sorted(routes or [], key=lambda r: not r.get("primary")):
        primary, color = _route_style(rt)
        ln, = ax.plot([0.05, 0.15], [y, y], color=color, lw=3.2 if primary else 2.6,
                      ls="-" if primary else (0, (4, 2)), transform=ax.transAxes, solid_capstyle="round")
        if primary:
            ln.set_path_effects([pe.Stroke(linewidth=5.5, foreground="white", alpha=0.9), pe.Normal()])
        ax.text(0.19, y, _wrap(rt.get("label") or "Route", 58), color="white", fontsize=8, ha="left", va="center")
        y -= 0.10
    if markers:
        for kind, face, name, x in (("start", "#2ECC71", "Start", 0.07), ("end", "#FF3B30", "Destination", 0.45)):
            if any(m.get("kind") == kind for m in markers):
                ax.scatter([x], [0.12], s=110, c=face, edgecolors="white", linewidths=1.3,
                           transform=ax.transAxes, zorder=5)
                ax.text(x, 0.12, "A" if kind == "start" else "B", color="white", fontsize=7, fontweight="bold",
                        ha="center", va="center", transform=ax.transAxes, zorder=6)
                ax.text(x + 0.05, 0.12, name, color="white", fontsize=8, ha="left", va="center")


def _draw_panel(pax, kind, item, routes, markers):
    if kind == "routes":
        _draw_route_panel(pax, routes, markers)
    elif kind == "layer":
        _draw_layer_panel(pax, item)
    else:
        _draw_unavailable_panel(pax, item)


def _collect_panels(routes, markers, overlays, unavailable):
    panels = []
    if routes or markers:
        panels.append(("routes", None))
    panels += [("layer", ov) for ov in overlays or []]
    panels += [("missing", u) for u in unavailable or []]
    return panels


def _save_legend_strip(panels, routes, markers, path, fig_w=14):
    """Legends as their own image, so the map image can be zoomed without them."""
    n_rows = int(math.ceil(len(panels) / PANEL_COLS))
    fig = plt.figure(figsize=(fig_w, n_rows * (PANEL_H_IN + 0.3)), dpi=120, facecolor="black")
    gs = fig.add_gridspec(n_rows, PANEL_COLS, left=0.02, right=0.98, top=0.98, bottom=0.02,
                          hspace=0.12, wspace=0.06)
    for i, (kind, item) in enumerate(panels):
        _draw_panel(fig.add_subplot(gs[i // PANEL_COLS, i % PANEL_COLS]), kind, item, routes, markers)
    fig.savefig(path, dpi=160, facecolor="black")
    plt.close(fig)


def _save_map_only(rgb, extent, path, routes, markers, max_dim=6000, min_dim=2400):
    """Borderless map: image pixel (x, y) maps linearly to (lon, lat) across `extent`
    (pixel 0,0 = north-west corner), so a zoomable viewer can convert taps to coordinates."""
    h, w = rgb.shape[:2]
    longest = max(h, w, 1)
    k = float(np.clip(longest, min_dim, max_dim)) / longest
    W, H = max(1, int(round(w * k))), max(1, int(round(h * k)))
    dpi = 100
    fig = plt.figure(figsize=(W / dpi, H / dpi), dpi=dpi, facecolor="black")
    ax = fig.add_axes([0, 0, 1, 1])
    ax.axis("off")
    ax.imshow(np.clip(rgb, 0, 1), origin="upper", extent=extent, aspect="auto", interpolation="lanczos")
    _draw_routes(ax, routes, markers, scale=max(1.0, W / 2200.0))
    ax.set_xlim(extent[0], extent[1])
    ax.set_ylim(extent[2], extent[3])
    fig.savefig(path, dpi=dpi, facecolor="black")
    plt.close(fig)


# --------------------------------------------------------------------------- #
# Main entry point
# --------------------------------------------------------------------------- #
def render_2d_hillshade(data: np.ndarray, extent, ppd: float, output_path: str,
                        azimuth: float = 315, altitude: float = 45,
                        vert_exag: float = 2.5, title: str = "Mars MOLA Terrain",
                        overlays=None, routes=None, markers=None, unavailable=None,
                        map_only=False, max_dim=6000, legend_path=None):
    """
    overlays: [{"rgba": HxWx4 float 0..1, "opacity": 0..1, "relief": bool, "title": str,
                "provenance": "streamed"|"modeled", "source": str, "note": str, "legend": dict}]
    routes:   [{"path": [[lat, lon], ...], "primary": bool, "label": str, "color": optional}]
    markers:  [{"kind": "start"|"end", "lat": float, "lon": float}]
    unavailable: [{"title": str, "note": str}]   layers requested but not drawn (shown as a legend panel)
    map_only: borderless high-res map for zoomable viewers; legends go to `legend_path` as a separate PNG
    """
    if data.size == 0:
        raise ValueError("Empty data array")

    norm = build_mars_norm(data)
    meters_per_deg = 59150.0
    dx = (meters_per_deg / max(ppd, 1.0))

    ls = LightSource(azdeg=azimuth, altdeg=altitude)
    valid = data[~np.isnan(data)]
    fill_v = float(np.nanmin(valid)) if valid.size > 0 else 0.0
    clean = np.nan_to_num(data, nan=fill_v)
    hillshade = ls.hillshade(clean, dx=dx, dy=dx, vert_exag=vert_exag)

    rgb_colors = MARS_CMAP(norm(data))
    intensity = (hillshade ** 0.75)[:, :, None]
    rgb_blended = rgb_colors[:, :, :3] * intensity
    nan_mask = np.isnan(data)
    rgb_blended[nan_mask] = [0.0, 0.0, 0.0]

    if overlays:
        rgb_blended = _composite_overlays(rgb_blended, hillshade, overlays, data.shape)
        rgb_blended[nan_mask] = [0.0, 0.0, 0.0]

    panels = _collect_panels(routes, markers, overlays, unavailable)

    if map_only:
        _save_map_only(rgb_blended, extent, output_path, routes, markers, max_dim=int(max_dim or 6000))
        if legend_path and panels:
            _save_legend_strip(panels, routes, markers, legend_path)
        return output_path

    aspect_ratio = data.shape[1] / max(data.shape[0], 1)
    fig_w = 14
    fig_h = max(6, fig_w / aspect_ratio)
    n_rows = int(math.ceil(len(panels) / PANEL_COLS)) if panels else 0

    fig = plt.figure(figsize=(fig_w, fig_h + n_rows * (PANEL_H_IN + 0.35)), dpi=120, facecolor="black")
    gs = fig.add_gridspec(1 + n_rows, PANEL_COLS, height_ratios=[fig_h] + [PANEL_H_IN] * n_rows,
                          left=0.06, right=0.96, top=0.95, bottom=0.02, hspace=0.16, wspace=0.06)
    ax = fig.add_subplot(gs[0, :])
    ax.set_facecolor("black")
    ax.imshow(np.clip(rgb_blended, 0, 1), origin="upper", extent=extent, aspect="auto",
              interpolation="lanczos")

    sm = plt.cm.ScalarMappable(cmap=MARS_CMAP, norm=norm)
    sm.set_array([])
    cbar = fig.colorbar(sm, ax=ax, shrink=0.75, pad=0.02)
    cbar.set_label("Elevation (m)", fontsize=11, color="white")
    cbar.ax.yaxis.set_tick_params(color="white", labelcolor="white")
    tick_vals = [a[0] for a in norm.anchors]
    cbar.set_ticks(tick_vals)          # the colorbar axis is in metres (the old code passed 0..1 values)
    cbar.set_ticklabels([f"{int(v):,}" for v in tick_vals])

    _draw_routes(ax, routes, markers)
    # keep the axes at the requested region even if a path touches the edge
    ax.set_xlim(extent[0], extent[1])
    ax.set_ylim(extent[2], extent[3])

    for i, (kind, item) in enumerate(panels):
        _draw_panel(fig.add_subplot(gs[1 + i // PANEL_COLS, i % PANEL_COLS]), kind, item, routes, markers)

    ax.set_xlabel("Longitude (°E)", fontsize=11, color="white")
    ax.set_ylabel("Latitude (°N)", fontsize=11, color="white")
    ax.tick_params(colors="white")
    for spine in ax.spines.values(): spine.set_color("#444444")
    ax.set_title(title, fontsize=13, fontweight="bold", color="white", pad=12)

    plt.savefig(output_path, dpi=160, bbox_inches="tight", facecolor="black")
    plt.close(fig)
    return output_path