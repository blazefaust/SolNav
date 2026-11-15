"""SolNav's NASA proxy endpoints, ported from SolNav's stdlib server (main.py v7) into a FastAPI router.

Same URLs and same JSON shapes as the original, so SolNav's index.html works unchanged:
    /api/nasa/weather?source=msl|insight
    /api/nasa/mola?lat=..&lon=..
    /api/nasa/mola/profile?points=lat,lon;lat,lon
    /api/nasa/nomenclature?q=..&limit=..
    /api/nasa/horizons
    /api/nasa/images?q=..&limit=..
Everything is streamed live from NASA/JPL; nothing is stored on disk.
"""
import concurrent.futures
import json
import re
import threading
import time
import urllib.parse
import urllib.request

from fastapi import APIRouter

router = APIRouter(prefix="/api/nasa", tags=["nasa"])

UA = {"User-Agent": "SolNav/v7"}

_CACHE: dict = {}
_LOCK = threading.Lock()
TTL = {"weather_msl": 4, "weather_insight": 4, "horizons": 4,
       "mola": 86400, "nomenclature": 3600, "images": 3600}


def _get(key, ttl):
    with _LOCK:
        hit = _CACHE.get(key)
    if hit and time.time() - hit[1] < ttl:
        return hit[0]
    return None


def _set(key, val):
    with _LOCK:
        _CACHE[key] = (val, time.time())


def _fetch_json(url, timeout=8):
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode())


# --------------------------------------------------------------------------- #
def fetch_weather(source="msl"):
    key = f"weather_{source}"
    cached = _get(key, TTL.get(key, 900))
    if cached:
        return cached
    try:
        if source == "insight":
            url = "https://api.nasa.gov/insight_weather/?api_key=DEMO_KEY&feedtype=json&ver=1.0"
        else:
            url = "https://mars.nasa.gov/rss/api/?feed=weather&category=msl&feedtype=json"
        data = _fetch_json(url)
        _set(key, data)
        return data
    except Exception as e:
        return {"error": str(e), "source": "NASA Weather Service"}


def fetch_mola(lat, lon):
    try:
        r_lat, r_lon = round(float(lat), 2), round(float(lon), 2)
        key = f"mola_{r_lat}_{r_lon}"
        cached = _get(key, TTL["mola"])
        if cached is not None:
            return cached
        url = ("https://trek.nasa.gov/mars/trekarcgis/rest/services/"
               "mola128_mola64_merge_90Nto90S_SimpleC_clon0/ImageServer/identify")
        geom = json.dumps({"x": r_lon, "y": r_lat, "spatialReference": {"wkid": 104905}})
        params = {"geometry": geom, "geometryType": "esriGeometryPoint", "f": "json"}
        data = _fetch_json(url + "?" + urllib.parse.urlencode(params), timeout=6)
        val = data.get("value")
        if val is not None and val != "NoData":
            res = {"lat": float(lat), "lon": float(lon), "elevation": int(round(float(val))),
                   "source": "NASA MOLA DEM ImageServer"}
            _set(key, res)
            return res
    except Exception:
        pass
    try:
        return {"lat": float(lat), "lon": float(lon), "elevation": None, "error": "Identify failed"}
    except (TypeError, ValueError):
        return {"lat": 0.0, "lon": 0.0, "elevation": None, "error": "Bad coordinates"}


def fetch_mola_profile(points_str):
    pts = []
    for pair in points_str.split(";"):
        if "," in pair:
            try:
                a, b = pair.split(",")[:2]
                pts.append((float(a), float(b)))
            except ValueError:
                pass
    if not pts:
        return {"points": []}

    def one(pt):
        d = fetch_mola(pt[0], pt[1])
        return {"lat": pt[0], "lon": pt[1], "elevation": d.get("elevation", 0) or 0}

    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as ex:
        results = list(ex.map(one, pts))
    return {"points": results, "source": "NASA MOLA DEM Profile"}


def fetch_horizons():
    cached = _get("horizons", TTL["horizons"])
    if cached:
        return cached
    today = time.strftime("%Y-%m-%d")
    tomorrow = time.strftime("%Y-%m-%d", time.gmtime(time.time() + 86400))
    params = {"format": "json", "COMMAND": "'499'", "EPHEM_TYPE": "OBSERVER", "CENTER": "'500@399'",
              "START_TIME": today, "STOP_TIME": tomorrow, "STEP_SIZE": "1d"}
    try:
        res = _fetch_json("https://ssd.jpl.nasa.gov/api/horizons.api?" + urllib.parse.urlencode(params))
        for line in res.get("result", "").splitlines():
            if re.match(r"^\s*\d{4}-[A-Za-z]{3}-\d{2}\s+\d{2}:\d{2}", line):
                p = line.split()
                if len(p) >= 47:
                    parsed = {"date": p[0], "obs_sub_lon": float(p[32]), "obs_sub_lat": float(p[33]),
                              "sun_sub_lon": float(p[34]), "sun_sub_lat": float(p[35]),
                              "sun_mars_dist_au": float(p[42]), "earth_mars_dist_au": float(p[44]),
                              "light_travel_minutes": float(p[46]), "source": "NASA/JPL Horizons API"}
                    _set("horizons", parsed)
                    return parsed
    except Exception as e:
        print(f"[NASA Horizons Error]: {e}")
    return {"error": "Failed to query JPL Horizons ephemeris"}


def fetch_nomenclature(query, limit=20):
    key = f"nom_{query.lower()}_{limit}"
    cached = _get(key, TTL["nomenclature"])
    if cached:
        return cached
    url = "https://trek.nasa.gov/mars/trekarcgis/rest/services/combinedNom/MapServer/0/query"
    escaped = query.replace("'", "''")
    params = {"where": f"UPPER(clean_name) LIKE UPPER('%{escaped}%')",
              "outFields": "clean_name,type,center_lat,center_lon,diameter,origin,link,x,y",
              "returnGeometry": "false", "f": "json"}
    try:
        data = _fetch_json(url + "?" + urllib.parse.urlencode(params))
        feats = [f["attributes"] for f in data.get("features", [])[:limit]]
        res = {"query": query, "count": len(feats), "features": feats, "source": "NASA Mars Trek GIS"}
        _set(key, res)
        return res
    except Exception as e:
        print(f"[NASA Nomenclature Error]: {e}")
        return {"query": query, "count": 0, "features": [], "error": str(e)}


def fetch_images(query, limit=8):
    key = f"img_{query.lower()}_{limit}"
    cached = _get(key, TTL["images"])
    if cached:
        return cached
    url = "https://images-api.nasa.gov/search?" + urllib.parse.urlencode({"q": query, "media_type": "image"})
    try:
        data = _fetch_json(url)
        items = data.get("collection", {}).get("items", [])
        out_items = []
        for item in items[:limit]:
            d = (item.get("data") or [{}])[0]
            links = item.get("links") or [{}]
            out_items.append({"title": d.get("title"),
                              "description": (d.get("description") or "")[:140],
                              "thumb": links[0].get("href") if links else "",
                              "nasa_id": d.get("nasa_id")})
        out = {"query": query, "images": out_items, "source": "NASA Images API"}
        _set(key, out)
        return out
    except Exception as e:
        print(f"[NASA Images Error]: {e}")
        return {"query": query, "images": [], "error": str(e)}


# --------------------------------------------------------------------------- #
# Plain `def` endpoints: FastAPI runs them in a worker thread, so the blocking urllib calls are fine.
@router.get("/weather")
def weather(source: str = "msl"):
    return fetch_weather(source)


@router.get("/mola")
def mola(lat: float = 0.0, lon: float = 0.0):
    return fetch_mola(lat, lon)


@router.get("/mola/profile")
def mola_profile(points: str = ""):
    return fetch_mola_profile(points)


@router.get("/nomenclature")
def nomenclature(q: str = "", limit: int = 15):
    return fetch_nomenclature(q, limit)


@router.get("/horizons")
def horizons():
    return fetch_horizons()


@router.get("/images")
def images(q: str = "", limit: int = 8):
    return fetch_images(q, limit)