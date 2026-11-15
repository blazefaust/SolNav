"""
mola_engine.py — Multi-tile MOLA ingestion + on-demand ROI mosaicking.

All .img tiles in data/ are indexed (memory-mapped, nothing loaded into RAM).
crop_roi() reads only the pixels a region needs, stitching across tile borders.
If tiles of different resolutions overlap (e.g. a global 16 ppd file plus 128 ppd
tiles), the finest data wins and coarser data fills any gaps.
"""
import re
import os
import pathlib
import hashlib
import xml.etree.ElementTree as ET
from typing import Dict, Optional, Tuple, List
import numpy as np
from PIL import Image

LANDMARKS = {
    "Olympus Mons":       {"lat": (13.0, 24.0),   "lon": (220.0, 234.0)},
    "Valles Marineris":   {"lat": (-22.0, 2.0),   "lon": (260.0, 310.0)},
    "Tharsis Volcanoes":  {"lat": (-15.0, 30.0),  "lon": (210.0, 260.0)},
    "Gale Crater":        {"lat": (-7.0, -3.0),   "lon": (136.0, 140.0)},
    "Jezero Crater":      {"lat": (16.5, 20.5),   "lon": (75.5, 79.5)},
    "Hellas Basin":       {"lat": (-55.0, -25.0), "lon": (50.0, 95.0)},
    "North Pole Ice Cap": {"lat": (72.0, 90.0),   "lon": (0.0, 360.0)},
}

MEGDR_TABLE = {
    "a": {"ppd": 1,   "global": True,  "lat_span": 180.0, "lon_span": 360.0},
    "b": {"ppd": 2,   "global": True,  "lat_span": 180.0, "lon_span": 360.0},
    "c": {"ppd": 4,   "global": True,  "lat_span": 180.0, "lon_span": 360.0},
    "d": {"ppd": 8,   "global": True,  "lat_span": 180.0, "lon_span": 360.0},
    "e": {"ppd": 16,  "global": True,  "lat_span": 180.0, "lon_span": 360.0},
    "f": {"ppd": 32,  "global": True,  "lat_span": 180.0, "lon_span": 360.0},
    "g": {"ppd": 64,  "global": False, "lat_span": 44.0,  "lon_span": 90.0},
    "h": {"ppd": 128, "global": False, "lat_span": 44.0,  "lon_span": 90.0},
}

TILE_LAT_SPAN = 44.0
TILE_LON_SPAN = 90.0
METERS_PER_DEG = 59150.0  # Mars: 2*pi*3389.5 km / 360
DEFAULT_MAX_ROI_PIXELS = 9_000_000


# --------------------------------------------------------------------------- #
# Metadata parsing
# --------------------------------------------------------------------------- #
def _strip_ns(tag: str) -> str:
    return tag.split("}")[-1].lower() if "}" in tag else tag.lower()


def _default_meta() -> Dict:
    return {
        "lines": 0, "line_samples": 0, "sample_bits": 16, "sample_bytes": 2,
        "sample_type": "MSB_INTEGER", "image_start_byte": 0,
        "scaling_factor": 1.0, "offset": 0.0, "missing_constant": -32768,
        "westernmost_lon": None, "easternmost_lon": None,
        "minimum_lat": None, "maximum_lat": None, "map_resolution": None,
    }


def parse_pds4_xml(xml_path: str) -> Dict:
    tree = ET.parse(xml_path)
    root = tree.getroot()
    lines = samples = 0
    data_type_str = "SignedMSB2"
    offset_bytes = 0
    scale = 1.0
    value_offset = 0.0
    missing_constant = -32768
    west_lon = east_lon = north_lat = south_lat = map_res = None

    for elem in root.iter():
        tag = _strip_ns(elem.tag)
        if tag == "axis_array":
            seq_val = elem_val = None
            name_val = ""
            for child in elem:
                ctag = _strip_ns(child.tag)
                if ctag == "sequence_number" and child.text: seq_val = int(child.text.strip())
                elif ctag == "elements" and child.text: elem_val = int(child.text.strip())
                elif ctag == "axis_name" and child.text: name_val = child.text.strip().lower()
            if elem_val is not None:
                if seq_val == 1 or "line" in name_val: lines = elem_val
                elif seq_val == 2 or "sample" in name_val: samples = elem_val
        elif tag == "offset" and elem.text and elem.text.strip().isdigit():
            offset_bytes = int(elem.text.strip())
        elif tag == "data_type" and elem.text: data_type_str = elem.text.strip()
        elif tag == "scaling_factor" and elem.text:
            try: scale = float(elem.text.strip())
            except ValueError: pass
        elif tag == "value_offset" and elem.text:
            try: value_offset = float(elem.text.strip())
            except ValueError: pass
        elif tag == "missing_constant" and elem.text:
            try: missing_constant = int(float(elem.text.strip()))
            except ValueError: pass
        elif tag == "westernmost_longitude" and elem.text: west_lon = float(elem.text.strip())
        elif tag == "easternmost_longitude" and elem.text: east_lon = float(elem.text.strip())
        elif tag == "northernmost_latitude" and elem.text: north_lat = float(elem.text.strip())
        elif tag == "southernmost_latitude" and elem.text: south_lat = float(elem.text.strip())
        elif tag in ("map_resolution", "pixel_resolution") and elem.text:
            try: map_res = float(elem.text.strip())
            except ValueError: pass

    dt_upper = data_type_str.upper()
    sample_type = "MSB_INTEGER" if "MSB" in dt_upper else "LSB_INTEGER"
    m = re.search(r"(\d)\s*$", dt_upper)
    sample_bytes = int(m.group(1)) if m and int(m.group(1)) in (1, 2, 4) else 2

    return {
        "lines": lines, "line_samples": samples,
        "sample_bits": sample_bytes * 8, "sample_bytes": sample_bytes,
        "sample_type": sample_type, "image_start_byte": offset_bytes,
        "scaling_factor": scale, "offset": value_offset,
        "missing_constant": missing_constant,
        "westernmost_lon": west_lon, "easternmost_lon": east_lon,
        "minimum_lat": south_lat, "maximum_lat": north_lat,
        "map_resolution": map_res,
    }


def _universal_reconcile(meta: dict, img_path: str) -> dict:
    """Derive grid geometry from file size + filename (XML extents/resolution
    are not trusted: tags and units vary)."""
    file_size = os.path.getsize(img_path) - int(meta.get("image_start_byte", 0) or 0)
    total_pixels = file_size // meta["sample_bytes"]

    fname = pathlib.Path(img_path).name.lower()
    m = re.search(r"meg([a-z])(\d{2})([ns])(\d{3})([a-h])", fname)

    # Global grid: 180*ppd x 360*ppd pixels
    ppd_g = (total_pixels / 64800.0) ** 0.5
    if ppd_g > 0 and abs(ppd_g - round(ppd_g)) < 1e-4:
        ppd = float(round(ppd_g))
        meta["map_resolution"] = ppd
        meta["maximum_lat"] = 90.0
        meta["minimum_lat"] = -90.0
        meta["westernmost_lon"] = 0.0
        meta["easternmost_lon"] = 360.0
        meta["lines"] = int(round(180 * ppd))
        meta["line_samples"] = int(round(360 * ppd))
        return meta

    # Otherwise a 44 x 90 degree tile
    ppd_t = (total_pixels / (TILE_LAT_SPAN * TILE_LON_SPAN)) ** 0.5
    if ppd_t > 0 and abs(ppd_t - round(ppd_t)) < 1e-4:
        ppd = float(round(ppd_t))
    elif m and m.group(5) in MEGDR_TABLE:
        ppd = float(MEGDR_TABLE[m.group(5)]["ppd"])
    else:
        raise ValueError(
            f"{pathlib.Path(img_path).name}: {total_pixels} samples is neither a "
            f"global MEGDR nor a 44x90 tile."
        )

    if m:
        _, lat_str, hemi, lon_str, _res = m.groups()
        upper_lat = float(lat_str) if hemi == "n" else -float(lat_str)
        west_lon = float(lon_str)
    else:
        if None in (meta.get("maximum_lat"), meta.get("westernmost_lon")):
            raise ValueError(
                f"Filename '{fname}' does not follow the MEGDR convention "
                f"(e.g. megt44n000hb.img) and no XML bounds were found."
            )
        upper_lat = float(meta["maximum_lat"])
        west_lon = float(meta["westernmost_lon"])

    meta["map_resolution"] = ppd
    meta["maximum_lat"] = upper_lat
    meta["minimum_lat"] = upper_lat - TILE_LAT_SPAN
    meta["westernmost_lon"] = west_lon
    meta["easternmost_lon"] = west_lon + TILE_LON_SPAN
    meta["lines"] = int(round(TILE_LAT_SPAN * ppd))
    meta["line_samples"] = int(round(TILE_LON_SPAN * ppd))
    return meta


def _prepare(img_path: str, xml_path: Optional[str]):
    """Resolve metadata + numpy dtype for one file and sanity-check its size."""
    img_path = str(pathlib.Path(img_path).resolve())
    meta = _default_meta()
    if xml_path and os.path.exists(xml_path):
        try:
            meta = parse_pds4_xml(xml_path)
        except Exception as e:
            print(f"[WARN] Could not parse {xml_path}: {e}. Using defaults.")
            meta = _default_meta()

    meta = _universal_reconcile(meta, img_path)
    lines, samples = meta["lines"], meta["line_samples"]
    bpp, start = meta["sample_bytes"], meta["image_start_byte"]

    if bpp == 1:
        dt = np.dtype("i1")
    else:
        endian = ">" if "MSB" in meta["sample_type"] else "<"
        dt = np.dtype(f"{endian}{ {2: 'i2', 4: 'i4'}[bpp] }")

    expected = lines * samples * bpp
    avail = os.path.getsize(img_path) - start
    if avail < expected:
        raise ValueError(
            f"{pathlib.Path(img_path).name} holds {avail} bytes after header; "
            f"expected {expected} for {lines}x{samples}."
        )
    return img_path, meta, dt


# --------------------------------------------------------------------------- #
# Single-file loader (kept for backwards compatibility)
# --------------------------------------------------------------------------- #
def load_mola_img(img_path: str, xml_path: Optional[str] = None) -> Tuple[np.ndarray, dict]:
    img_path, meta, dt = _prepare(img_path, xml_path)
    lines, samples = meta["lines"], meta["line_samples"]
    raw = np.fromfile(img_path, dtype=dt, count=lines * samples, offset=meta["image_start_byte"])
    grid = raw.reshape((lines, samples))
    elevation = grid.astype(np.float32)
    elevation[grid == meta["missing_constant"]] = np.nan
    sc, off = meta["scaling_factor"], meta["offset"]
    if sc != 1.0 or off != 0.0:
        elevation = elevation * sc + off
    return elevation, meta


def _find_sidecar_xml(search_dir: pathlib.Path, img: pathlib.Path) -> Optional[pathlib.Path]:
    for f in search_dir.iterdir():
        if f.is_file() and f.suffix.lower() == ".xml" and f.stem.lower() == img.stem.lower():
            return f
    return None


def auto_detect_mola_files(search_dir: pathlib.Path) -> Tuple[str, Optional[str]]:
    """Single-file detector (legacy). Use load_mola_dataset() for multi-tile."""
    search_dir = pathlib.Path(search_dir)
    if not search_dir.exists():
        return "", None
    all_img = sorted(f for f in search_dir.iterdir()
                     if f.is_file() and f.suffix.lower() == ".img")
    meg = [f for f in all_img if f.name.lower().startswith("meg")]
    cands = meg if meg else all_img
    if not cands:
        return "", None
    xml = _find_sidecar_xml(search_dir, cands[0])
    return str(cands[0]), (str(xml) if xml else None)


# --------------------------------------------------------------------------- #
# Multi-tile dataset
# --------------------------------------------------------------------------- #
class MolaTile:
    """One memory-mapped MOLA file with its geographic extent."""

    def __init__(self, img_path, xml_path=None):
        img_path, meta, dt = _prepare(str(img_path), str(xml_path) if xml_path else None)
        self.path = pathlib.Path(img_path)
        self.xml = pathlib.Path(xml_path) if xml_path else None
        self.name = self.path.name
        self.meta = meta
        self.ppd = float(meta["map_resolution"])
        self.south = float(meta["minimum_lat"])
        self.north = float(meta["maximum_lat"])
        self.west = float(meta["westernmost_lon"])
        self.east = float(meta["easternmost_lon"])
        self.lines = int(meta["lines"])
        self.samples = int(meta["line_samples"])
        self.missing = meta["missing_constant"]
        self.scale = meta["scaling_factor"]
        self.offset = meta["offset"]
        self.mm = np.memmap(img_path, dtype=dt, mode="r",
                            offset=meta["image_start_byte"],
                            shape=(self.lines, self.samples))

    @property
    def lat_span(self): return self.north - self.south

    @property
    def lon_span(self): return self.east - self.west

    def overlaps(self, lat_lo, lat_hi, lon_lo, lon_hi) -> bool:
        return not (self.north <= lat_lo or self.south >= lat_hi or
                    self.east <= lon_lo or self.west >= lon_hi)


class MolaDataset:
    """A set of MolaTiles presented as one virtual elevation grid."""

    def __init__(self, tiles: List[MolaTile], skipped: Optional[List[str]] = None):
        if not tiles:
            raise ValueError("MolaDataset needs at least one tile")
        self.tiles = sorted(tiles, key=lambda t: (t.ppd, t.name))  # coarse -> fine
        self.skipped = skipped or []
        south = min(t.south for t in tiles)
        north = max(t.north for t in tiles)
        west = min(t.west for t in tiles)
        east = max(t.east for t in tiles)
        ppd = max(t.ppd for t in tiles)
        self.meta = {
            "minimum_lat": south, "maximum_lat": north,
            "westernmost_lon": west, "easternmost_lon": east,
            "map_resolution": ppd,
            "lines": int(round((north - south) * ppd)),
            "line_samples": int(round((east - west) * ppd)),
            "tile_count": len(tiles),
        }
        h = hashlib.sha1()
        for t in self.tiles:
            h.update(f"{t.name}:{os.path.getsize(t.path)}".encode())
        self.signature = h.hexdigest()[:12]

    def overlapping(self, lat_lo, lat_hi, lon_lo, lon_hi) -> List[MolaTile]:
        return [t for t in self.tiles if t.overlaps(lat_lo, lat_hi, lon_lo, lon_hi)]

    def coverage(self, lat_range, lon_range, n: int = 40) -> float:
        """Fraction (0..1) of a lat/lon box that is covered by loaded tiles."""
        lats = np.linspace(min(lat_range), max(lat_range), n)
        lons = np.linspace(min(lon_range), max(lon_range), n)
        LA, LO = np.meshgrid(lats, lons, indexing="ij")
        covered = np.zeros(LA.shape, dtype=bool)
        for t in self.tiles:
            covered |= (LA >= t.south) & (LA <= t.north) & (LO >= t.west) & (LO <= t.east)
        return float(covered.mean())

    def describe(self) -> List[dict]:
        return [{
            "file": t.name, "ppd": t.ppd,
            "south": t.south, "north": t.north, "west": t.west, "east": t.east,
            "shape": [t.lines, t.samples],
        } for t in self.tiles]


def discover_mola_tiles(search_dir: pathlib.Path) -> List[Tuple[pathlib.Path, Optional[pathlib.Path]]]:
    search_dir = pathlib.Path(search_dir)
    if not search_dir.exists():
        return []
    imgs = sorted(f for f in search_dir.iterdir()
                  if f.is_file() and f.suffix.lower() == ".img")
    # Prefer topography (megt*). Avoid mixing in areoid (mega*) / radius (megr*).
    topo = [f for f in imgs if f.name.lower().startswith("megt")]
    meg = [f for f in imgs if f.name.lower().startswith("meg")]
    chosen = topo or meg or imgs
    return [(f, _find_sidecar_xml(search_dir, f)) for f in chosen]


def load_mola_dataset(search_dir: pathlib.Path) -> MolaDataset:
    found = discover_mola_tiles(search_dir)
    if not found:
        raise FileNotFoundError(f"No .img files found in {pathlib.Path(search_dir).resolve()}")
    tiles, skipped = [], []
    for img, xml in found:
        try:
            tiles.append(MolaTile(img, xml))
        except Exception as e:
            msg = f"{img.name}: {e}"
            print(f"[WARN] Skipping {msg}")
            skipped.append(msg)
    if not tiles:
        raise ValueError("No usable MOLA tiles. " + " | ".join(skipped))
    return MolaDataset(tiles, skipped)


def effective_ppd(roi: np.ndarray, lat_axis: np.ndarray) -> float:
    """Actual pixels-per-degree of a cropped ROI (it may be downsampled)."""
    span = abs(float(lat_axis[0]) - float(lat_axis[-1]))
    return (roi.shape[0] - 1) / span if span > 0 else 1.0


# --------------------------------------------------------------------------- #
# ROI cropping
# --------------------------------------------------------------------------- #
def _paint_tile(out: np.ndarray, tile: MolaTile, lat_axis: np.ndarray, lon_axis: np.ndarray) -> None:
    """Nearest-neighbour resample the part of `tile` that falls on the output
    grid into `out`, without overwriting with missing values."""
    lat_in = (lat_axis <= tile.north) & (lat_axis >= tile.south)
    lon_in = (lon_axis >= tile.west) & (lon_axis <= tile.east)
    if not lat_in.any() or not lon_in.any():
        return
    ri = np.nonzero(lat_in)[0]
    ci = np.nonzero(lon_in)[0]

    src_r = np.clip(np.floor((tile.north - lat_axis[ri]) / tile.lat_span * tile.lines).astype(np.int64),
                    0, tile.lines - 1)
    src_c = np.clip(np.floor((lon_axis[ci] - tile.west) / tile.lon_span * tile.samples).astype(np.int64),
                    0, tile.samples - 1)

    r_lo, r_hi = int(src_r.min()), int(src_r.max()) + 1
    c_lo, c_hi = int(src_c.min()), int(src_c.max()) + 1
    window = np.asarray(tile.mm[r_lo:r_hi, c_lo:c_hi])          # reads only this window
    block = window[np.ix_(src_r - r_lo, src_c - c_lo)]

    vals = block.astype(np.float32)
    vals[block == tile.missing] = np.nan
    if tile.scale != 1.0 or tile.offset != 0.0:
        vals = vals * tile.scale + tile.offset

    sub = out[np.ix_(ri, ci)]
    ok = ~np.isnan(vals)
    sub[ok] = vals[ok]
    out[np.ix_(ri, ci)] = sub


def _crop_dataset(ds: MolaDataset, roi_lat, roi_lon, max_pixels: int):
    m = ds.meta
    lat_min, lat_max = min(roi_lat), max(roi_lat)
    lon_min, lon_max = min(roi_lon), max(roi_lon)

    c_lat_min = max(lat_min, m["minimum_lat"])
    c_lat_max = min(lat_max, m["maximum_lat"])
    c_lon_min = max(lon_min, m["westernmost_lon"])
    c_lon_max = min(lon_max, m["easternmost_lon"])

    names = ", ".join(t.name for t in ds.tiles)
    if c_lat_min >= c_lat_max or c_lon_min >= c_lon_max:
        raise ValueError(
            f"Selected region [{lat_min:.1f}..{lat_max:.1f}°N, {lon_min:.1f}..{lon_max:.1f}°E] "
            f"is outside the loaded data extent "
            f"[{m['minimum_lat']:.1f}..{m['maximum_lat']:.1f}°N, "
            f"{m['westernmost_lon']:.1f}..{m['easternmost_lon']:.1f}°E]."
        )

    hits = ds.overlapping(c_lat_min, c_lat_max, c_lon_min, c_lon_max)
    if not hits:
        raise ValueError(
            f"No loaded tile covers [{lat_min:.1f}..{lat_max:.1f}°N, {lon_min:.1f}..{lon_max:.1f}°E]. "
            f"Loaded: {names}"
        )

    ppd = max(t.ppd for t in hits)
    rows = max(2, int(round((c_lat_max - c_lat_min) * ppd)))
    cols = max(2, int(round((c_lon_max - c_lon_min) * ppd)))
    if rows * cols > max_pixels:
        f = (max_pixels / float(rows * cols)) ** 0.5
        rows, cols = max(2, int(rows * f)), max(2, int(cols * f))

    lat_axis = np.linspace(c_lat_max, c_lat_min, rows)   # north -> south (row 0 = north)
    lon_axis = np.linspace(c_lon_min, c_lon_max, cols)

    out = np.full((rows, cols), np.nan, dtype=np.float32)
    for t in sorted(hits, key=lambda t: t.ppd):           # coarse first, fine overwrites
        _paint_tile(out, t, lat_axis, lon_axis)

    if np.isnan(out).all():
        raise ValueError("Region contains no valid elevation samples (gap between loaded tiles?).")
    return out, lat_axis, lon_axis


def _crop_array(elevation: np.ndarray, meta: dict, roi_lat, roi_lon):
    lines, samples = elevation.shape
    w, e = meta["westernmost_lon"], meta["easternmost_lon"]
    s, n = meta["minimum_lat"], meta["maximum_lat"]

    lat_min, lat_max = min(roi_lat), max(roi_lat)
    lon_min, lon_max = min(roi_lon), max(roi_lon)
    c_lat_min, c_lat_max = max(lat_min, s), min(lat_max, n)
    c_lon_min, c_lon_max = max(lon_min, w), min(lon_max, e)

    if c_lat_min >= c_lat_max or c_lon_min >= c_lon_max:
        raise ValueError(
            f"Selected region [{lat_min:.1f}..{lat_max:.1f}°N, {lon_min:.1f}..{lon_max:.1f}°E] "
            f"does not overlap active tile extent [{s:.1f}..{n:.1f}°N, {w:.1f}..{e:.1f}°E]."
        )

    lat_span, lon_span = n - s, e - w
    r0 = int(np.floor(((n - c_lat_max) / lat_span) * (lines - 1)))
    r1 = int(np.ceil(((n - c_lat_min) / lat_span) * (lines - 1))) + 1
    c0 = int(np.floor(((c_lon_min - w) / lon_span) * (samples - 1)))
    c1 = int(np.ceil(((c_lon_max - w) / lon_span) * (samples - 1))) + 1
    r0 = max(0, min(r0, lines - 2)); r1 = max(r0 + 2, min(r1, lines))
    c0 = max(0, min(c0, samples - 2)); c1 = max(c0 + 2, min(c1, samples))

    roi = elevation[r0:r1, c0:c1].copy()
    lat_axis = np.linspace(c_lat_max, c_lat_min, roi.shape[0])
    lon_axis = np.linspace(c_lon_min, c_lon_max, roi.shape[1])
    return roi, lat_axis, lon_axis


def crop_roi(source, meta: dict,
             roi_lat: Tuple[float, float], roi_lon: Tuple[float, float],
             max_pixels: int = DEFAULT_MAX_ROI_PIXELS
             ) -> Tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Crop a region from a MolaDataset (multi-tile) or a plain 2-D array.
    Returns (roi, lat_axis [north->south], lon_axis [west->east]).
    Negative longitudes are accepted and converted to 0..360."""
    roi_lon = tuple(x + 360.0 if x < 0 else x for x in roi_lon)
    if isinstance(source, MolaDataset):
        return _crop_dataset(source, roi_lat, roi_lon, max_pixels)
    return _crop_array(source, meta, roi_lat, roi_lon)


# --------------------------------------------------------------------------- #
# Export + statistics
# --------------------------------------------------------------------------- #
def export_heightmap_16bit(roi_elev: np.ndarray, output_path: str) -> None:
    arr = roi_elev.copy()
    valid = arr[~np.isnan(arr)]
    vmin = float(np.min(valid)) if valid.size > 0 else 0.0
    vmax = float(np.max(valid)) if valid.size > 0 else 1.0
    arr = np.nan_to_num(arr, nan=vmin)
    norm = (arr - vmin) / (vmax - vmin) if vmax > vmin else np.zeros_like(arr)
    u16 = np.clip(norm * 65535.0, 0, 65535).astype(np.uint16)
    Image.fromarray(u16).save(output_path)


def compute_terrain_statistics(roi: np.ndarray, meta: dict,
                               lat_bounds: Tuple[float, float],
                               lon_bounds: Tuple[float, float]) -> dict:
    valid_mask = ~np.isnan(roi)
    valid = roi[valid_mask]
    if valid.size == 0:
        return {"error": "No valid elevation samples in region"}

    ppd = meta["map_resolution"]   # pass the ROI's effective ppd here

    lat_lo = max(min(lat_bounds), meta["minimum_lat"])
    lat_hi = min(max(lat_bounds), meta["maximum_lat"])
    lon_lo = max(min(lon_bounds), meta["westernmost_lon"])
    lon_hi = min(max(lon_bounds), meta["easternmost_lon"])
    mean_lat = (lat_lo + lat_hi) / 2.0
    cos_lat = max(0.05, float(np.cos(np.radians(mean_lat))))

    dy = METERS_PER_DEG / max(ppd, 1.0)
    dx = dy * cos_lat

    clean = np.nan_to_num(roi, nan=float(np.mean(valid)))
    gy, gx = np.gradient(clean, dy, dx)
    slope_deg = np.degrees(np.arctan(np.sqrt(gx**2 + gy**2)))
    slope_valid = slope_deg[valid_mask]

    height_km = (lat_hi - lat_lo) * (METERS_PER_DEG / 1000.0)
    width_km = (lon_hi - lon_lo) * (METERS_PER_DEG / 1000.0) * cos_lat

    return {
        "min_elevation_m": float(np.min(valid)),
        "max_elevation_m": float(np.max(valid)),
        "mean_elevation_m": float(np.mean(valid)),
        "elevation_range_m": float(np.max(valid) - np.min(valid)),
        "std_elevation_m": float(np.std(valid)),
        "mean_slope_deg": float(np.mean(slope_valid)),
        "max_slope_deg": float(np.max(slope_valid)),
        "pct_flat_terrain": float(np.mean(slope_valid < 5.0) * 100),
        "pct_steep_terrain": float(np.mean(slope_valid > 20.0) * 100),
        "width_km": float(width_km),
        "height_km": float(height_km),
        "approx_area_km2": float(width_km * height_km),
        "resolution_ppd": float(ppd),
        "resolution_m_per_pixel": float(dy),
        "shape": [int(roi.shape[0]), int(roi.shape[1])],
    }