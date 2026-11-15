"""renderer_3d.py — Offline Plotly WebGL 3D terrain with physically-correct vertical scale."""
import numpy as np
import plotly.graph_objects as go

MAX_GRID_DIM = 700        # max surface vertices per side (keeps WebGL smooth)
KM_PER_DEG = 59.15        # Mars


def _block_mean(a: np.ndarray, step: int) -> np.ndarray:
    """NaN-aware area average (anti-aliased downsample)."""
    r = (a.shape[0] // step) * step
    c = (a.shape[1] // step) * step
    blk = a[:r, :c].reshape(r // step, step, c // step, step)
    valid = ~np.isnan(blk)
    cnt = valid.sum(axis=(1, 3))
    tot = np.where(valid, blk, 0.0).sum(axis=(1, 3))
    return np.where(cnt > 0, tot / np.maximum(cnt, 1), np.nan).astype(np.float32)


def _block_axis(ax: np.ndarray, step: int) -> np.ndarray:
    n = (len(ax) // step) * step
    return ax[:n].reshape(-1, step).mean(axis=1)


ROUTE_COLORS = ["#FF2BD6", "#00E5FF", "#FFEB3B", "#76FF03", "#FF9100"]


def _sample_elev(z: np.ndarray, lat_axis: np.ndarray, lon_axis: np.ndarray,
                 lat: np.ndarray, lon: np.ndarray) -> np.ndarray:
    """Bilinear elevation lookup on the (already decimated) surface grid, so a route
    drawn at these heights sits exactly on the surface the viewer sees."""
    la = np.asarray(lat_axis, dtype=np.float64)
    lo = np.asarray(lon_axis, dtype=np.float64)
    zz = np.asarray(z, dtype=np.float64)
    if la[0] > la[-1]:                       # north->south axis: flip so it ascends
        la, zz = la[::-1], zz[::-1, :]
    zz = np.where(np.isnan(zz), float(np.nanmean(zz)), zz)
    fi = np.interp(lat, la, np.arange(len(la)))
    fj = np.interp(lon, lo, np.arange(len(lo)))
    i0 = np.clip(np.floor(fi).astype(int), 0, max(len(la) - 2, 0))
    j0 = np.clip(np.floor(fj).astype(int), 0, max(len(lo) - 2, 0))
    i1 = np.minimum(i0 + 1, len(la) - 1)
    j1 = np.minimum(j0 + 1, len(lo) - 1)
    ti, tj = fi - i0, fj - j0
    top = zz[i0, j0] * (1 - tj) + zz[i0, j1] * tj
    bot = zz[i1, j0] * (1 - tj) + zz[i1, j1] * tj
    return top * (1 - ti) + bot * ti


def render_3d_plotly(roi_elev: np.ndarray, lat_axis: np.ndarray, lon_axis: np.ndarray,
                     vert_exag: float, output_html: str, title: str,
                     routes=None, markers=None) -> str:
    """routes: [{"label", "path": [[lat, lon], ...], "primary": bool}]
    markers: [{"kind": "start"|"end", "lat", "lon"}]  (both optional)."""
    z = np.asarray(roi_elev, dtype=np.float32)

    # Anti-aliased decimation (replaces z[::step, ::step], which aliased steep terrain)
    step = int(np.ceil(max(z.shape) / MAX_GRID_DIM))
    if step > 1:
        z = _block_mean(z, step)
        lat_axis = _block_axis(np.asarray(lat_axis), step)
        lon_axis = _block_axis(np.asarray(lon_axis), step)

    valid = z[~np.isnan(z)]
    if valid.size == 0:
        raise ValueError("No valid elevation samples to render.")
    zmin, zmax = float(valid.min()), float(valid.max())
    z_range_m = max(zmax - zmin, 1.0)

    lon_g, lat_g = np.meshgrid(lon_axis, lat_axis)

    # Real-world footprint
    dlat = abs(float(lat_axis[0] - lat_axis[-1]))
    dlon = abs(float(lon_axis[-1] - lon_axis[0]))
    mean_lat = float(np.mean(lat_axis))
    height_km = dlat * KM_PER_DEG
    width_km = dlon * KM_PER_DEG * max(0.05, np.cos(np.radians(mean_lat)))
    max_km = max(width_km, height_km, 1e-6)

    aspect_x = (width_km / max_km) * 2.0
    aspect_y = (height_km / max_km) * 2.0
    # FIX: vertical size is the TRUE relief over the footprint x the requested
    # exaggeration (was a hard-coded 0.4, which ignored vert_exag entirely).
    aspect_z = (z_range_m * vert_exag / 1000.0) / max_km * 2.0
    aspect_z = float(np.clip(aspect_z, 0.03, 1.2))

    surface = go.Surface(
        x=lon_g, y=lat_g, z=z,                 # true elevation in metres (NaN = gap)
        colorscale="earth",
        cmin=zmin, cmax=zmax,
        colorbar=dict(title="Elevation (m)"),
        hovertemplate="Lon: %{x:.2f}°E<br>Lat: %{y:.2f}°N<br>Elev: %{z:.0f} m<extra></extra>",
        lighting=dict(ambient=0.55, diffuse=0.85, roughness=0.9, specular=0.05, fresnel=0.05),
        lightposition=dict(x=-8000, y=-8000, z=6000),
        showlegend=False,
    )
    fig = go.Figure(data=[surface])
    z_top = zmax
    lift = 0.012 * z_range_m          # float the line just above the terrain so it never z-fights

    for i, rt in enumerate(routes or []):
        pts = np.asarray(rt.get("path") or [], dtype=np.float64)
        if pts.ndim != 2 or len(pts) < 2:
            continue
        rz = _sample_elev(z, lat_axis, lon_axis, pts[:, 0], pts[:, 1]) + lift
        z_top = max(z_top, float(rz.max()))
        primary = bool(rt.get("primary"))
        color = ROUTE_COLORS[i % len(ROUTE_COLORS)]
        fig.add_trace(go.Scatter3d(
            x=pts[:, 1], y=pts[:, 0], z=rz, mode="lines",
            name=str(rt.get("label") or f"Route {i + 1}"),
            line=dict(color=color, width=9 if primary else 5),
            opacity=1.0 if primary else 0.8,
            hovertemplate="Lon: %{x:.2f}°E<br>Lat: %{y:.2f}°N<br>Elev: %{z:.0f} m<extra>" +
                          str(rt.get("label") or "Route") + "</extra>",
        ))

    mk = {"start": ("A  START", "#3DDC84"), "end": ("B  DEST", "#FF4D4D")}
    for m in markers or []:
        if m.get("kind") not in mk or m.get("lat") is None or m.get("lon") is None:
            continue
        label, color = mk[m["kind"]]
        mz = float(_sample_elev(z, lat_axis, lon_axis, np.array([m["lat"]]), np.array([m["lon"]]))[0]) + lift
        z_top = max(z_top, mz)
        fig.add_trace(go.Scatter3d(
            x=[m["lon"]], y=[m["lat"]], z=[mz], mode="markers+text",
            text=[label], textposition="top center", textfont=dict(color=color, size=13),
            marker=dict(size=7, color=color, line=dict(color="white", width=2)),
            name=label.replace("  ", " "), hoverinfo="skip",
        ))

    fig.update_layout(
        title=dict(text=f"{title} ({vert_exag:g}× vertical exaggeration)", x=0.5),
        scene=dict(
            xaxis_title="Longitude (°E)", yaxis_title="Latitude (°N)",
            zaxis_title="Elevation (m)",
            zaxis=dict(range=[zmin, z_top + 0.02 * z_range_m]),
            aspectmode="manual",
            aspectratio=dict(x=aspect_x, y=aspect_y, z=aspect_z),
            camera=dict(eye=dict(x=1.4, y=-1.6, z=0.9)),
        ),
        margin=dict(l=0, r=0, t=40, b=0),
        template="plotly_dark",
        showlegend=bool(routes),
        legend=dict(x=0.01, y=0.99, bgcolor="rgba(0,0,0,0.5)"),
    )
    fig.write_html(output_html, include_plotlyjs=True)
    return output_html