from __future__ import annotations

import bz2
import hashlib
import hmac
import io
import json
import logging
import math
import os
from pathlib import Path
import tarfile
import tempfile
import threading
import time
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from html.parser import HTMLParser
from typing import Any, Dict, List, Optional, Tuple
import xml.etree.ElementTree as ET

import numpy as np
from fastapi import FastAPI, HTTPException, Request, Response
from PIL import Image
from pydantic import BaseModel, Field


logging.basicConfig(
    level=os.environ.get("RADAR_LOG_LEVEL", "INFO").upper(),
    format="%(asctime)s %(levelname)s [%(name)s] %(message)s",
)
logger = logging.getLogger("radar-proxy")


DWD_RV_URL = os.environ.get(
    "DWD_RV_URL",
    "https://opendata.dwd.de/weather/radar/composite/rv/DE1200_RV_LATEST.tar.bz2",
)
DWD_RV_INDEX_URL = os.environ.get(
    "DWD_RV_INDEX_URL",
    "https://opendata.dwd.de/weather/radar/composite/rv/",
)
DWD_WMS_URL = os.environ.get(
    "DWD_WMS_URL",
    "https://maps.dwd.de/geoserver/dwd/ows",
)
DWD_WMS_LAYER = os.environ.get("DWD_WMS_LAYER", "Radar_rv_product_1x1km_ger")
ICON_FORECAST_HOURS = int(os.environ.get("DWD_ICON_FORECAST_HOURS", "120"))
ICON_RAW_FORECAST_HOURS = int(os.environ.get("DWD_ICON_RAW_FORECAST_HOURS", "72"))
ICON_RAW_MAX_FRAMES = int(os.environ.get("DWD_ICON_RAW_MAX_FRAMES", "72"))
ICON_RAW_STEP_HOURS = int(os.environ.get("DWD_ICON_RAW_STEP_HOURS", "1"))
ICON_RAW_BASE_URL = os.environ.get("DWD_ICON_RAW_BASE_URL", "https://opendata.dwd.de/weather/nwp/icon-eu/grib/")
DISK_CACHE_MAX_AGE_SECONDS = int(os.environ.get("DWD_RADAR_DISK_CACHE_MAX_AGE_SECONDS", "86400"))
DISK_CACHE_PRUNE_INTERVAL_SECONDS = int(os.environ.get("DWD_RADAR_DISK_CACHE_PRUNE_INTERVAL_SECONDS", "3600"))
NATIVE_FRAME_STEP_MINUTES = int(os.environ.get("DWD_RADAR_NATIVE_FRAME_STEP_MINUTES", "10"))
ICON_WMS_RECOLOR = os.environ.get("DWD_ICON_WMS_RECOLOR", "true").lower() in {"1", "true", "yes"}
ICON_RAW_MODE = os.environ.get("DWD_ICON_RAW_MODE", "auto").lower()
ICON_PRECIP_LAYERS = [
    item.strip()
    for item in os.environ.get(
        "DWD_ICON_PRECIP_LAYERS",
        "Icon-eu_reg00625_fd_sl_TOTPREC01H,Icon-eu_reg00625_fd_sl_TOTPREC03H,Icon_reg025_fd_sl_TOTPREC,Aicon_reg025_fd_sl_TOTPREC",
    ).split(",")
    if item.strip()
]
DWD_RADAR_RENDER_MODE = os.environ.get("DWD_RADAR_RENDER_MODE", "native").lower()
CACHE_SECONDS = int(os.environ.get("DWD_RADAR_CACHE_SECONDS", "240"))
PAST_HOURS = int(os.environ.get("DWD_RADAR_PAST_HOURS", "24"))
PAST_STEP_MINUTES = int(os.environ.get("DWD_RADAR_PAST_STEP_MINUTES", "15"))
BACKGROUND_HISTORY = os.environ.get("DWD_RADAR_BACKGROUND_HISTORY", "").lower() in {"1", "true", "yes"}
REFRESH_INTERVAL_SECONDS = int(os.environ.get("DWD_RADAR_REFRESH_INTERVAL_SECONDS", "300"))
STARTUP_WARM = os.environ.get("DWD_RADAR_STARTUP_WARM", "true").lower() in {"1", "true", "yes"}
WARM_TILES = os.environ.get("DWD_RADAR_WARM_TILES", "true").lower() in {"1", "true", "yes"}
WARM_FRAME_LIMIT = int(os.environ.get("DWD_RADAR_WARM_FRAME_LIMIT", "25"))
# Render warm tiles across this many threads. Defaults to the core count so
# both vCPUs are used; numpy/PIL release the GIL during render/PNG encode.
WARM_WORKERS = max(1, int(os.environ.get("DWD_RADAR_WARM_WORKERS", str(os.cpu_count() or 2))))
WARM_DETAIL_FRAME_LIMIT = int(os.environ.get("DWD_RADAR_WARM_DETAIL_FRAME_LIMIT", "6"))
WARM_ZOOMS = tuple(int(item) for item in os.environ.get("DWD_RADAR_WARM_ZOOMS", "5,6").split(",") if item.strip())
WARM_DETAIL_ZOOMS = tuple(int(item) for item in os.environ.get("DWD_RADAR_WARM_DETAIL_ZOOMS", "7").split(",") if item.strip())
TILE_MAX_ZOOM = int(os.environ.get("DWD_RADAR_TILE_MAX_ZOOM", "13"))
HOTSPOT_WARM = os.environ.get("DWD_RADAR_HOTSPOT_WARM", "true").lower() in {"1", "true", "yes"}
HOTSPOT_LAT = float(os.environ.get("DWD_RADAR_HOTSPOT_LAT", "50.088"))
HOTSPOT_LON = float(os.environ.get("DWD_RADAR_HOTSPOT_LON", "9.064"))
HOTSPOT_RADIUS_TILES = int(os.environ.get("DWD_RADAR_HOTSPOT_RADIUS_TILES", "1"))
HOTSPOT_ZOOMS = tuple(int(item) for item in os.environ.get("DWD_RADAR_HOTSPOT_ZOOMS", "8,9").split(",") if item.strip())
# Detail zooms warmed only around the hotspots (not the whole bbox), covering
# the app's local open view (~z8) so playback there is served from cache
# instead of rendering ~18 tiles per frame on demand.
HOTSPOT_DETAIL_ZOOMS = tuple(int(item) for item in os.environ.get("DWD_RADAR_HOTSPOT_DETAIL_ZOOMS", "7,8,9").split(",") if item.strip())
HOTSPOT_DETAIL_FRAME_LIMIT = int(os.environ.get("DWD_RADAR_HOTSPOT_DETAIL_FRAME_LIMIT", "96"))
HOTSPOT_DETAIL_HALF_KM = float(os.environ.get("DWD_RADAR_HOTSPOT_DETAIL_HALF_KM", "75"))
RADAR_PROXY_TOKEN = os.environ.get("RADAR_PROXY_TOKEN") or os.environ.get("WEATHERMAT_RADAR_TOKEN") or ""
DISK_CACHE_DIR = Path(os.environ["RADAR_DISK_CACHE_DIR"]) if os.environ.get("RADAR_DISK_CACHE_DIR") else None
TILE_SIZE = 512
try:
    TILE_RENDER_SCALE = max(1, min(4, int(os.environ.get("RADAR_TILE_RENDER_SCALE", "2"))))
except ValueError:
    TILE_RENDER_SCALE = 2
GRID_WIDTH = 1100
GRID_HEIGHT = 1200
APP_VERSION = "smooth-bilinear-warm-2026-07-03"

# Hybrid rain palette: blue for light/moderate rain, warning colors
# (yellow/orange/red) from "kraeftig" upwards. Must stay in sync with
# RadarLegendStep.steps in the iOS client.
RAIN_COLOR_STEPS = (
    (0.01, 0.3, (207, 238, 253, 105)),
    (0.3, 0.8, (111, 197, 247, 135)),
    (0.8, 1.8, (42, 120, 214, 165)),
    (1.8, 4.0, (247, 208, 56, 195)),
    (4.0, 8.0, (242, 140, 40, 220)),
    (8.0, 9999.0, (217, 48, 37, 238)),
)

# --- DWD warning push (APNs) ---
APNS_TEAM_ID = os.environ.get("APNS_TEAM_ID", "")
APNS_KEY_ID = os.environ.get("APNS_KEY_ID", "")
APNS_KEY_PATH = os.environ.get("APNS_KEY_PATH", "")
APNS_TOPIC = os.environ.get("APNS_TOPIC", "de.praxishartlep.weathermat")
APNS_USE_SANDBOX = os.environ.get("APNS_USE_SANDBOX", "true").lower() in {"1", "true", "yes"}
APNS_MIN_SEVERITY = os.environ.get("APNS_MIN_SEVERITY", "Moderate")
WARNING_POLL_SECONDS = int(os.environ.get("WARNING_POLL_SECONDS", "300"))
PUSH_STATE_PATH = Path(os.environ.get("PUSH_STATE_PATH", "push_state.json"))
HOTSPOTS_STATE_PATH = Path(os.environ.get("HOTSPOTS_STATE_PATH", "hotspots.json"))
_SEVERITY_RANK = {"Minor": 0, "Moderate": 1, "Severe": 2, "Extreme": 3}
TILE_CACHE_VERSION = os.environ.get("RADAR_TILE_CACHE_VERSION", APP_VERSION)
WEB_MERCATOR_LIMIT = 20037508.342789244

# Practical coverage of the DE1200 composite for the legacy raster renderer.
# For WMS mode the DWD service itself clips the layer; keep this broad enough
# that valid edge tiles are not discarded before the WMS request is made.
RADAR_BBOX = (
    float(os.environ.get("DWD_RADAR_WEST", "1.4")),
    float(os.environ.get("DWD_RADAR_SOUTH", "45.6")),
    float(os.environ.get("DWD_RADAR_EAST", "18.8")),
    float(os.environ.get("DWD_RADAR_NORTH", "56.3")),
)
WARM_BBOX = (
    float(os.environ.get("DWD_RADAR_WARM_WEST", "4.7")),
    float(os.environ.get("DWD_RADAR_WARM_SOUTH", "46.7")),
    float(os.environ.get("DWD_RADAR_WARM_EAST", "16.0")),
    float(os.environ.get("DWD_RADAR_WARM_NORTH", "55.4")),
)


@dataclass(frozen=True)
class RadarFrame:
    frame_id: str
    time: datetime
    is_forecast: bool
    image: Image.Image
    layer_name: str | None = None
    reference_time: datetime | None = None
    precipitation_type: str = "unknown"


@dataclass
class RadarCache:
    loaded_at: float
    frames: List[RadarFrame]
    tile_cache: Dict[Tuple[str, int, int, int], bytes]
    tile_cache_lock: threading.Lock = field(default_factory=threading.Lock)


app = FastAPI(title="WeatherMat DWD Radar Proxy")
_cache: RadarCache | None = None
_cache_lock = threading.Lock()
_cache_build_lock = threading.Lock()
_refreshing = False
_refresh_loop_started = False
_warm_lock = threading.Lock()
_warming = False
_warmed_cache_id: float | None = None
_warm_stats = {
    "lastStartedAt": None,
    "lastFinishedAt": None,
    "lastCacheId": None,
    "rendered": 0,
    "reused": 0,
    "frames": 0,
}
_dynamic_hotspots: List[Tuple[float, float]] = []
_dynamic_hotspots_lock = threading.Lock()
_dynamic_hotspots_loaded = False
_icon_raw_cache_lock = threading.Lock()
_icon_raw_cache: Dict[str, Any] = {
    "referenceTime": None,
    "runHour": None,
    "frames": [],
}
_last_disk_prune_at = 0.0
_last_disk_prune_lock = threading.Lock()
_metrics_lock = threading.Lock()
_metrics: Dict[str, Any] = {
    "startedAt": datetime.now(timezone.utc).isoformat(),
    "refreshCount": 0,
    "refreshErrors": 0,
    "lastRefreshStartedAt": None,
    "lastRefreshFinishedAt": None,
    "lastRefreshDurationSeconds": None,
    "lastRefreshError": None,
    "tileRequests": 0,
    "tileRendered": 0,
    "tileMemoryHits": 0,
    "tileDiskHits": 0,
    "tileErrors": 0,
    "wmsTileFailures": 0,
    "iconRawFrames": 0,
    "iconRawFailures": 0,
    "iconWmsFrames": 0,
    "lastIconRawRun": None,
    "lastIconRawCandidates": [],
    "iconRawCacheHits": 0,
    "diskCachePrunedFiles": 0,
}
_transparent_tile: bytes | None = None


@app.on_event("startup")
def startup() -> None:
    _load_dynamic_hotspots()
    _start_refresh_loop()
    _start_warning_poll()


@app.get("/ping")
def ping() -> dict:
    # Unauthenticated liveness probe for external uptime monitoring.
    # Deliberately returns no version or cache details.
    return {"ok": True}


@app.get("/health")
def health(request: Request) -> dict:
    _require_token(request)
    cache = _cache
    return {
        "ok": True,
        "version": APP_VERSION,
        "renderMode": DWD_RADAR_RENDER_MODE,
        "iconMode": ICON_RAW_MODE,
        "capabilities": _capabilities(),
        "frames": len(cache.frames) if cache is not None else 0,
        "loadedAt": cache.loaded_at if cache is not None else None,
        "refreshing": _refreshing,
        "refreshIntervalSeconds": REFRESH_INTERVAL_SECONDS,
        "warming": _warming,
        "warmStats": _warm_stats,
        "metrics": _metrics_snapshot(),
    }


@app.get("/timeline.json")
def timeline(request: Request) -> dict:
    _require_token(request)
    try:
        cache = _ensure_cache()
    except Exception as error:
        raise HTTPException(status_code=503, detail=f"Radar cache build failed: {error}") from error
    return {
        "source": "WeatherMat RadarEngine · DWD RV Rohdaten/ICON-EU",
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "tileMaxZoom": 18 if DWD_RADAR_RENDER_MODE == "wms" else TILE_MAX_ZOOM,
        "iconMode": ICON_RAW_MODE,
        "capabilities": _capabilities(),
        "frames": [
            {
                "id": frame.frame_id,
                "time": frame.time.isoformat(),
                "isForecast": frame.is_forecast,
                "source": _frame_source(frame),
                "referenceTime": frame.reference_time.isoformat() if frame.reference_time else None,
                "renderVersion": APP_VERSION,
                "precipitationType": frame.precipitation_type,
            }
            for frame in cache.frames
        ],
    }


@app.get("/tiles/{frame_id}/{z}/{x}/{y}.png")
def tile(request: Request, frame_id: str, z: int, x: int, y: int) -> Response:
    _require_token(request)
    try:
        cache = _ensure_cache()
    except Exception as error:
        raise HTTPException(status_code=503, detail=f"Radar cache build failed: {error}") from error
    frame = next((item for item in cache.frames if item.frame_id == frame_id), None)
    if frame is None:
        raise HTTPException(status_code=404, detail="Unknown radar frame")

    _metric_increment("tileRequests")
    data, _ = _tile_bytes(cache, frame, z, x, y)
    return Response(content=data, media_type="image/png", headers={"Cache-Control": "public, max-age=600"})


def _frame_source(frame: RadarFrame) -> str:
    if frame.layer_name and frame.layer_name != DWD_WMS_LAYER:
        return "icon-eu-wms"
    if frame.frame_id.startswith("iconraw--"):
        return "icon-eu-raw"
    if frame.layer_name == DWD_WMS_LAYER:
        return "dwd-radar-wms"
    return "dwd-rv"


def _capabilities() -> dict:
    icon_raw_available = _icon_raw_decoder_available()
    return {
        "nativeDwdRv": DWD_RADAR_RENDER_MODE in {"native", "hybrid", "raw"},
        "serverRenderedTiles": True,
        "iconForecast": bool(ICON_PRECIP_LAYERS),
        "iconRawGrib": icon_raw_available,
        "precipitationType": "rain-snow-when-raw",
        "hotspotWarm": HOTSPOT_WARM,
        "hotspotZooms": list(HOTSPOT_ZOOMS),
        "tileMaxZoom": TILE_MAX_ZOOM,
    }


@app.get("/warm")
def warm(request: Request) -> dict:
    _require_token(request)
    cache = _ensure_cache()
    scheduled = _schedule_tile_warm(cache)
    return {
        "ok": True,
        "scheduled": scheduled,
        "warming": _warming,
        "warmStats": _warm_stats,
    }


@app.post("/warm-location")
@app.get("/warm-location")
def warm_location(request: Request, lat: float, lon: float) -> dict:
    _require_token(request)
    if not (-90 <= lat <= 90 and -180 <= lon <= 180):
        raise HTTPException(status_code=400, detail="Invalid coordinate")
    with _dynamic_hotspots_lock:
        point = (round(lat, 4), round(lon, 4))
        _dynamic_hotspots[:] = [item for item in _dynamic_hotspots if item != point]
        _dynamic_hotspots.insert(0, point)
        del _dynamic_hotspots[8:]
    _save_dynamic_hotspots()
    cache = _ensure_cache()
    scheduled = _schedule_tile_warm(cache, force=True)
    return {
        "ok": True,
        "scheduled": scheduled,
        "hotspots": _dynamic_hotspots_snapshot(),
        "warmStats": _warm_stats,
    }


@app.get("/metrics")
def metrics(request: Request) -> dict:
    _require_token(request)
    cache = _cache
    return {
        "ok": True,
        "version": APP_VERSION,
        "frames": len(cache.frames) if cache is not None else 0,
        "loadedAt": cache.loaded_at if cache is not None else None,
        "warming": _warming,
        "warmStats": _warm_stats,
        "metrics": _metrics_snapshot(),
        "hotspots": _dynamic_hotspots_snapshot(),
    }

# --- Warning push: registration + APNs delivery ---

class PushLocation(BaseModel):
    lat: float = Field(ge=-90, le=90)
    lon: float = Field(ge=-180, le=180)
    name: str = ""


class PushRegistration(BaseModel):
    token: str = Field(min_length=32, max_length=200)
    locations: List[PushLocation] = Field(max_length=12)


class PushUnregistration(BaseModel):
    token: str = Field(min_length=32, max_length=200)


_push_lock = threading.Lock()
_push_state: Dict[str, Any] = {"registrations": {}, "seen": {}}
_push_state_loaded = False
_apns_jwt_cache: Tuple[str, float] | None = None
_warning_poll_started = False


def _push_configured() -> bool:
    return bool(APNS_TEAM_ID and APNS_KEY_ID and APNS_KEY_PATH and Path(APNS_KEY_PATH).exists())


def _load_push_state() -> None:
    global _push_state, _push_state_loaded
    if _push_state_loaded:
        return
    _push_state_loaded = True
    try:
        if PUSH_STATE_PATH.exists():
            data = json.loads(PUSH_STATE_PATH.read_text())
            if isinstance(data, dict):
                _push_state = {
                    "registrations": data.get("registrations", {}),
                    "seen": data.get("seen", {}),
                }
    except (OSError, ValueError) as error:
        logger.warning("push state unreadable, starting fresh: %s", error)


def _save_push_state() -> None:
    try:
        PUSH_STATE_PATH.write_text(json.dumps(_push_state))
    except OSError as error:
        logger.warning("push state write failed: %s", error)


def _load_dynamic_hotspots() -> None:
    # Dynamic hotspots live in memory, so a container restart (deploy, monthly
    # rebuild, OOM) would drop every user's warmed location. Persist them so the
    # proxy keeps warming detail zooms across restarts even before the app
    # re-registers the location.
    global _dynamic_hotspots_loaded
    if _dynamic_hotspots_loaded:
        return
    _dynamic_hotspots_loaded = True
    try:
        if HOTSPOTS_STATE_PATH.exists():
            data = json.loads(HOTSPOTS_STATE_PATH.read_text())
            if isinstance(data, list):
                points = [
                    (round(float(item["lat"]), 4), round(float(item["lon"]), 4))
                    for item in data
                    if isinstance(item, dict) and "lat" in item and "lon" in item
                ]
                with _dynamic_hotspots_lock:
                    _dynamic_hotspots[:] = points[:8]
    except (OSError, ValueError, KeyError, TypeError) as error:
        logger.warning("hotspots state unreadable, starting fresh: %s", error)


def _save_dynamic_hotspots() -> None:
    with _dynamic_hotspots_lock:
        payload = [{"lat": lat, "lon": lon} for lat, lon in _dynamic_hotspots]
    try:
        HOTSPOTS_STATE_PATH.write_text(json.dumps(payload))
    except OSError as error:
        logger.warning("hotspots state write failed: %s", error)


@app.post("/push/register")
def push_register(request: Request, payload: PushRegistration) -> dict:
    _require_token(request)
    with _push_lock:
        _load_push_state()
        _push_state["registrations"][payload.token] = {
            "locations": [loc.model_dump() for loc in payload.locations],
            "updatedAt": datetime.now(timezone.utc).isoformat(),
        }
        _save_push_state()
        count = len(_push_state["registrations"])
    _metric_set("pushRegistrations", count)
    return {"ok": True, "registrations": count, "pushConfigured": _push_configured()}


@app.post("/push/unregister")
def push_unregister(request: Request, payload: PushUnregistration) -> dict:
    _require_token(request)
    with _push_lock:
        _load_push_state()
        _push_state["registrations"].pop(payload.token, None)
        _push_state["seen"].pop(payload.token, None)
        _save_push_state()
        count = len(_push_state["registrations"])
    _metric_set("pushRegistrations", count)
    return {"ok": True, "registrations": count}


def _apns_bearer_token() -> str:
    global _apns_jwt_cache
    now = time.time()
    if _apns_jwt_cache is not None and now - _apns_jwt_cache[1] < 45 * 60:
        return _apns_jwt_cache[0]
    import jwt as pyjwt

    key = Path(APNS_KEY_PATH).read_text()
    token = pyjwt.encode(
        {"iss": APNS_TEAM_ID, "iat": int(now)},
        key,
        algorithm="ES256",
        headers={"kid": APNS_KEY_ID},
    )
    _apns_jwt_cache = (token, now)
    return token


_APNS_HOSTS = {"production": "api.push.apple.com", "sandbox": "api.sandbox.push.apple.com"}


def _apns_post(device_token: str, env: str, title: str, subtitle: str, body: str, collapse_id: str, critical: bool) -> str:
    """One APNs request against the given environment. Returns:
    'ok', 'bad-env' (token belongs to the other environment), 'drop'
    (token gone), or 'error' (transient)."""
    import httpx

    payload = {
        "aps": {
            "alert": {"title": title, "subtitle": subtitle, "body": body},
            "sound": "default",
            "thread-id": "dwd-warnings",
            "interruption-level": "time-sensitive" if critical else "active",
        }
    }
    headers = {
        "authorization": f"bearer {_apns_bearer_token()}",
        "apns-topic": APNS_TOPIC,
        "apns-push-type": "alert",
        "apns-priority": "10",
        "apns-collapse-id": collapse_id[:64],
    }
    try:
        with httpx.Client(http2=True, timeout=15) as client:
            response = client.post(
                f"https://{_APNS_HOSTS[env]}/3/device/{device_token}", json=payload, headers=headers
            )
        if response.status_code == 200:
            _metric_increment("pushSent")
            return "ok"
        reason = ""
        try:
            reason = (response.json() or {}).get("reason", "")
        except Exception:
            pass
        if response.status_code == 410 or reason == "Unregistered":
            return "drop"
        if response.status_code == 400 and reason in {"BadDeviceToken", "BadEnvironmentKeyInToken"}:
            return "bad-env"
        _metric_increment("pushErrors")
        logger.warning("APNs %s (%s): %s", response.status_code, env, reason or response.text[:120])
    except Exception as error:
        _metric_increment("pushErrors")
        logger.warning("APNs send failed (%s): %s", env, error)
    return "error"


def _deliver_apns(device_token: str, prior_env: Optional[str], **kwargs) -> Tuple[str, Optional[str]]:
    """Delivers to the correct APNs environment, auto-detecting sandbox vs
    production per token so Xcode dev builds and TestFlight/App Store builds
    both work off one server. Returns (result, working_env) with result in
    {'sent', 'drop', 'error'}."""
    default_first = "sandbox" if APNS_USE_SANDBOX else "production"
    order: List[str] = []
    for env in ([prior_env] if prior_env in _APNS_HOSTS else []) + [default_first, "production", "sandbox"]:
        if env not in order:
            order.append(env)

    saw_bad_env = False
    for env in order:
        status = _apns_post(device_token, env, **kwargs)
        if status == "ok":
            return "sent", env
        if status == "drop":
            return "drop", None
        if status == "bad-env":
            saw_bad_env = True
            continue
        return "error", None
    # Rejected as bad token by every environment → genuinely invalid, drop it.
    return ("drop" if saw_bad_env else "error"), None


def _fetch_alerts(lat: float, lon: float) -> List[Dict[str, Any]]:
    url = f"https://api.brightsky.dev/alerts?lat={lat:.4f}&lon={lon:.4f}"
    try:
        with urllib.request.urlopen(url, timeout=15) as response:
            data = json.loads(response.read())
        return data.get("alerts") or []
    except Exception as error:
        logger.warning("alert fetch failed for %.2f,%.2f: %s", lat, lon, error)
        return []


def _severity_title(severity: str) -> str:
    return {
        "Minor": "DWD Wetterhinweis",
        "Moderate": "DWD Wetterwarnung",
        "Severe": "DWD Unwetterwarnung",
        "Extreme": "DWD Extreme Unwetterwarnung",
    }.get(severity, "DWD Wetterwarnung")


def _poll_warnings_once() -> None:
    with _push_lock:
        _load_push_state()
        registrations = {
            token: dict(entry) for token, entry in _push_state["registrations"].items()
        }
    if not registrations:
        return

    # One alerts request per distinct (rounded) coordinate, shared by all devices.
    coord_alerts: Dict[Tuple[float, float], List[Dict[str, Any]]] = {}
    for entry in registrations.values():
        for loc in entry.get("locations", []):
            coord_alerts.setdefault((round(loc["lat"], 2), round(loc["lon"], 2)), [])
    for coord in coord_alerts:
        coord_alerts[coord] = _fetch_alerts(coord[0], coord[1])

    min_rank = _SEVERITY_RANK.get(APNS_MIN_SEVERITY, 1)
    dropped_tokens: List[str] = []
    newly_seen: Dict[str, List[str]] = {}
    learned_env: Dict[str, str] = {}

    for token, entry in registrations.items():
        with _push_lock:
            seen = set(_push_state["seen"].get(token, []))
        for loc in entry.get("locations", []):
            coord = (round(loc["lat"], 2), round(loc["lon"], 2))
            for alert in coord_alerts.get(coord, []):
                alert_id = str(alert.get("id") or "")
                event = alert.get("event_de") or ""
                headline = alert.get("headline_de") or event
                severity = alert.get("severity") or "Minor"
                if not alert_id or f"{alert_id}" in seen:
                    continue
                if _SEVERITY_RANK.get(severity, 0) < min_rank:
                    continue
                result, working_env = _deliver_apns(
                    token,
                    entry.get("apnsEnv"),
                    title=_severity_title(severity),
                    subtitle=loc.get("name") or "",
                    body=headline,
                    collapse_id=f"dwd-{alert_id}",
                    critical=_SEVERITY_RANK.get(severity, 0) >= 2,
                )
                if result == "drop":
                    dropped_tokens.append(token)
                    break
                if result == "error":
                    break  # transient — leave unseen so it retries next cycle
                if working_env:
                    learned_env[token] = working_env
                seen.add(alert_id)
        newly_seen[token] = sorted(seen)[-200:]

    with _push_lock:
        for token in dropped_tokens:
            _push_state["registrations"].pop(token, None)
            _push_state["seen"].pop(token, None)
            newly_seen.pop(token, None)
            learned_env.pop(token, None)
        for token, ids in newly_seen.items():
            if token in _push_state["registrations"]:
                _push_state["seen"][token] = ids
        for token, env in learned_env.items():
            if token in _push_state["registrations"]:
                _push_state["registrations"][token]["apnsEnv"] = env
        _save_push_state()
        _metric_set("pushRegistrations", len(_push_state["registrations"]))
    _metric_set("lastWarningPollAt", datetime.now(timezone.utc).isoformat())


def _warning_poll_loop() -> None:
    while True:
        time.sleep(max(60, WARNING_POLL_SECONDS))
        try:
            _poll_warnings_once()
        except Exception as error:
            logger.error("warning poll failed: %s", error)


def _start_warning_poll() -> None:
    global _warning_poll_started
    if _warning_poll_started:
        return
    _warning_poll_started = True
    if not _push_configured():
        logger.info("warning push inactive: APNs key not configured")
        return
    threading.Thread(target=_warning_poll_loop, daemon=True).start()
    logger.info("warning push poller started (every %ss, auto sandbox+production, first try: %s)",
                WARNING_POLL_SECONDS, "sandbox" if APNS_USE_SANDBOX else "production")



def _require_token(request: Request) -> None:
    if not RADAR_PROXY_TOKEN:
        return
    supplied = request.query_params.get("token") or request.headers.get("x-radar-token") or ""
    if not supplied or not _constant_time_equals(supplied, RADAR_PROXY_TOKEN):
        raise HTTPException(status_code=401, detail="Unauthorized")


def _constant_time_equals(lhs: str, rhs: str) -> bool:
    return hmac.compare_digest(lhs, rhs)


def _metric_increment(name: str, amount: int = 1) -> None:
    with _metrics_lock:
        _metrics[name] = int(_metrics.get(name, 0)) + amount


def _metric_set(name: str, value: Any) -> None:
    with _metrics_lock:
        _metrics[name] = value


def _metrics_snapshot() -> Dict[str, Any]:
    with _metrics_lock:
        return dict(_metrics)


def _dynamic_hotspots_snapshot() -> List[Dict[str, float]]:
    with _dynamic_hotspots_lock:
        return [{"lat": lat, "lon": lon} for lat, lon in _dynamic_hotspots]


def _icon_raw_decoder_available() -> bool:
    try:
        import eccodes  # type: ignore  # noqa: F401
        return True
    except Exception:
        return False


def _disk_tile_path(frame_id: str, z: int, x: int, y: int) -> Path | None:
    if DISK_CACHE_DIR is None:
        return None
    digest = hashlib.sha1(f"{TILE_CACHE_VERSION}|{frame_id}".encode("utf-8")).hexdigest()
    return DISK_CACHE_DIR / "tiles" / digest[:2] / digest / str(z) / str(x) / f"{y}.png"


def _read_disk_tile(frame_id: str, z: int, x: int, y: int) -> bytes | None:
    path = _disk_tile_path(frame_id, z, x, y)
    if path is None or not path.exists():
        return None
    try:
        return path.read_bytes()
    except OSError:
        return None


def _write_disk_tile(frame_id: str, z: int, x: int, y: int, data: bytes) -> None:
    path = _disk_tile_path(frame_id, z, x, y)
    if path is None:
        return
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        # Atomic write (temp + rename) so a concurrent reader never sees a
        # half-written PNG, and multiple workers can't corrupt the same tile.
        tmp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
        tmp.write_bytes(data)
        os.replace(tmp, path)
    except OSError as error:
        logger.warning("tile disk cache write failed: %s", error)


def _prune_disk_cache_if_needed(force: bool = False) -> None:
    global _last_disk_prune_at
    if DISK_CACHE_DIR is None or DISK_CACHE_MAX_AGE_SECONDS <= 0:
        return
    now = time.time()
    with _last_disk_prune_lock:
        if not force and now - _last_disk_prune_at < DISK_CACHE_PRUNE_INTERVAL_SECONDS:
            return
        _last_disk_prune_at = now

    root = DISK_CACHE_DIR / "tiles"
    if not root.exists():
        return
    cutoff = now - DISK_CACHE_MAX_AGE_SECONDS
    removed = 0
    for file_path in root.rglob("*.png"):
        try:
            if file_path.stat().st_mtime < cutoff:
                file_path.unlink()
                removed += 1
        except OSError:
            continue
    for dir_path in sorted((path for path in root.rglob("*") if path.is_dir()), key=lambda path: len(path.parts), reverse=True):
        try:
            dir_path.rmdir()
        except OSError:
            continue
    if removed:
        _metric_increment("diskCachePrunedFiles", removed)


def _tile_bytes(cache: RadarCache, frame: RadarFrame, z: int, x: int, y: int) -> Tuple[bytes, bool]:
    key = (frame.frame_id, z, x, y)
    with cache.tile_cache_lock:
        data = cache.tile_cache.get(key)
        if data is not None:
            cache.tile_cache.pop(key, None)
            cache.tile_cache[key] = data
    if data is None:
        data = _read_disk_tile(frame.frame_id, z, x, y)
        if data is not None:
            _metric_increment("tileDiskHits")
    else:
        _metric_increment("tileMemoryHits")
    if data is None:
        try:
            if frame.layer_name:
                data = _render_wms_tile(frame, z, x, y)
            elif DWD_RADAR_RENDER_MODE == "wms":
                data = _render_wms_tile(frame, z, x, y)
            else:
                data = _render_tile(frame.image, z, x, y)
        except Exception as error:
            _metric_increment("tileErrors")
            logger.error("tile render failed frame=%s z=%s x=%s y=%s: %s", frame.frame_id, z, x, y, error)
            data = _empty_tile()
        with cache.tile_cache_lock:
            while len(cache.tile_cache) > 12000:
                cache.tile_cache.pop(next(iter(cache.tile_cache)))
            cache.tile_cache[key] = data
        _write_disk_tile(frame.frame_id, z, x, y, data)
        _metric_increment("tileRendered")
        return data, True

    with cache.tile_cache_lock:
        cache.tile_cache.pop(key, None)
        cache.tile_cache[key] = data
    return data, False


def _ensure_cache() -> RadarCache:
    global _cache, _refreshing
    now = time.time()
    with _cache_lock:
        cache = _cache
        if cache is not None and now - cache.loaded_at <= CACHE_SECONDS:
            return cache
        stale_cache = cache

    # A stale-but-present cache is served immediately while a refresh runs in
    # the background. _schedule_refresh() acquires _cache_lock itself, so it
    # must be called *after* releasing the lock above — otherwise the
    # non-reentrant lock deadlocks and every later cache request hangs.
    if stale_cache is not None:
        _schedule_refresh()
        return stale_cache

    with _cache_build_lock:
        with _cache_lock:
            cache = _cache
            if cache is not None:
                return cache
        cache = _refresh_cache_blocking(include_history=False)
    if BACKGROUND_HISTORY:
        _schedule_refresh(include_history=True)
    return cache


def _start_refresh_loop() -> None:
    global _refresh_loop_started
    with _cache_lock:
        if _refresh_loop_started:
            return
        _refresh_loop_started = True
    threading.Thread(target=_refresh_loop, daemon=True).start()


def _refresh_loop() -> None:
    if STARTUP_WARM:
        _schedule_refresh()
    while True:
        time.sleep(max(60, REFRESH_INTERVAL_SECONDS))
        _schedule_refresh()


def _schedule_refresh(include_history: bool | None = None) -> bool:
    global _refreshing
    with _cache_lock:
        if _refreshing:
            return False
        _refreshing = True
    threading.Thread(
        target=_refresh_cache_background,
        args=(BACKGROUND_HISTORY if include_history is None else include_history,),
        daemon=True
    ).start()
    return True


def _refresh_cache_blocking(include_history: bool) -> RadarCache:
    global _cache
    started = time.time()
    _metric_set("lastRefreshStartedAt", datetime.now(timezone.utc).isoformat())
    fresh = _build_cache(include_history=include_history)
    with _cache_lock:
        _cache = fresh
        cache = _cache
    _metric_increment("refreshCount")
    _metric_set("lastRefreshError", None)
    _metric_set("lastRefreshFinishedAt", datetime.now(timezone.utc).isoformat())
    _metric_set("lastRefreshDurationSeconds", round(time.time() - started, 3))
    _schedule_tile_warm(cache)
    threading.Thread(target=_prune_disk_cache_if_needed, daemon=True).start()
    return cache


def _refresh_cache_background(include_history: bool = False) -> None:
    global _cache, _refreshing
    started = time.time()
    _metric_set("lastRefreshStartedAt", datetime.now(timezone.utc).isoformat())
    try:
        fresh = _build_cache(include_history=include_history)
        with _cache_lock:
            _cache = fresh
        _schedule_tile_warm(fresh)
        threading.Thread(target=_prune_disk_cache_if_needed, daemon=True).start()
        _metric_increment("refreshCount")
        _metric_set("lastRefreshError", None)
    except Exception as error:
        _metric_increment("refreshErrors")
        _metric_set("lastRefreshError", str(error))
        logger.error("background refresh failed: %s", error)
    finally:
        _metric_set("lastRefreshFinishedAt", datetime.now(timezone.utc).isoformat())
        _metric_set("lastRefreshDurationSeconds", round(time.time() - started, 3))
        with _cache_lock:
            _refreshing = False


def _build_cache(include_history: bool) -> RadarCache:
    return RadarCache(loaded_at=time.time(), frames=_download_frames(include_history=include_history), tile_cache={})


def _schedule_tile_warm(cache: RadarCache, force: bool = False) -> bool:
    global _warming, _warmed_cache_id
    if not WARM_TILES or not cache.frames:
        return False
    with _warm_lock:
        if _warming or (not force and _warmed_cache_id == cache.loaded_at):
            return False
        _warming = True
        _warmed_cache_id = cache.loaded_at
    threading.Thread(target=_warm_tiles_background, args=(cache, cache.loaded_at), daemon=True).start()
    return True


def _warm_tiles_background(cache: RadarCache, cache_id: float) -> None:
    global _warming, _warm_stats
    started = datetime.now(timezone.utc).isoformat()
    rendered = 0
    reused = 0
    warmed_frames = 0
    _warm_stats = {
        "lastStartedAt": started,
        "lastFinishedAt": None,
        "lastCacheId": cache_id,
        "rendered": 0,
        "reused": 0,
        "frames": 0,
    }

    hotspot_points = _all_hotspot_points()
    try:
        # Build the full tile worklist first, then render across WARM_WORKERS
        # threads so both vCPUs are used instead of one.
        tasks: List[Tuple[RadarFrame, int, int, int]] = []
        for frame_index, frame in enumerate(cache.frames[:max(1, WARM_FRAME_LIMIT)]):
            seen: set = set()
            zooms = list(WARM_ZOOMS)
            if frame_index < WARM_DETAIL_FRAME_LIMIT:
                zooms.extend(WARM_DETAIL_ZOOMS)
            for z in dict.fromkeys(zooms):
                for x, y in _combined_warm_tile_paths(z):
                    if (z, x, y) in seen:
                        continue
                    seen.add((z, x, y))
                    tasks.append((frame, z, x, y))
            # Local detail: warm the higher zooms only around the hotspots so
            # the app's ~z8 open view plays back from cache.
            if HOTSPOT_WARM and frame_index < HOTSPOT_DETAIL_FRAME_LIMIT:
                for z in HOTSPOT_DETAIL_ZOOMS:
                    for lat, lon in hotspot_points:
                        for x, y in _hotspot_view_tile_paths(z, lat, lon, HOTSPOT_DETAIL_HALF_KM):
                            if (z, x, y) in seen:
                                continue
                            seen.add((z, x, y))
                            tasks.append((frame, z, x, y))
            warmed_frames += 1

        def _warm_one(task: Tuple[RadarFrame, int, int, int]) -> bool:
            frame, z, x, y = task
            try:
                _, did_render = _tile_bytes(cache, frame, z, x, y)
                return did_render
            except Exception as tile_error:
                logger.error("warm tile failed: %s", tile_error)
                return False

        if WARM_WORKERS > 1 and len(tasks) > 1:
            with ThreadPoolExecutor(max_workers=WARM_WORKERS) as pool:
                results = list(pool.map(_warm_one, tasks))
        else:
            results = [_warm_one(task) for task in tasks]
        rendered = sum(1 for did in results if did)
        reused = len(results) - rendered
    except Exception as error:
        logger.error("tile warm failed: %s", error)
    finally:
        finished = datetime.now(timezone.utc).isoformat()
        _warm_stats = {
            "lastStartedAt": started,
            "lastFinishedAt": finished,
            "lastCacheId": cache_id,
            "rendered": rendered,
            "reused": reused,
            "frames": warmed_frames,
        }
        with _warm_lock:
            _warming = False
        threading.Thread(target=_prune_disk_cache_if_needed, daemon=True).start()


def _combined_warm_tile_paths(z: int) -> List[Tuple[int, int]]:
    paths = _warm_tile_paths(z)
    if HOTSPOT_WARM and z in HOTSPOT_ZOOMS:
        paths.extend(_hotspot_tile_paths(z))
        with _dynamic_hotspots_lock:
            hotspots = list(_dynamic_hotspots)
        for lat, lon in hotspots:
            paths.extend(_hotspot_tile_paths(z, lat=lat, lon=lon, radius=HOTSPOT_RADIUS_TILES))
    return list(dict.fromkeys(paths))


def _warm_tile_paths(z: int) -> List[Tuple[int, int]]:
    west, south, east, north = _intersection(WARM_BBOX, RADAR_BBOX) or WARM_BBOX
    min_x, min_y = _lon_lat_to_tile(west, north, z)
    max_x, max_y = _lon_lat_to_tile(east, south, z)
    return [
        (x, y)
        for x in range(min(min_x, max_x), max(min_x, max_x) + 1)
        for y in range(min(min_y, max_y), max(min_y, max_y) + 1)
    ]


def _hotspot_tile_paths(z: int, lat: float = HOTSPOT_LAT, lon: float = HOTSPOT_LON, radius: int = HOTSPOT_RADIUS_TILES) -> List[Tuple[int, int]]:
    center_x, center_y = _lon_lat_to_tile(lon, lat, z)
    tile_count = 2**z
    radius = max(0, radius)
    return [
        (x, y)
        for x in range(max(0, center_x - radius), min(tile_count - 1, center_x + radius) + 1)
        for y in range(max(0, center_y - radius), min(tile_count - 1, center_y + radius) + 1)
    ]


def _hotspot_view_tile_paths(z: int, lat: float, lon: float, half_km: float) -> List[Tuple[int, int]]:
    """Tiles covering a ~`half_km` box around a point — tight enough that
    warming higher zooms stays cheap (a handful of tiles per hotspot)."""
    dlat = half_km / 111.0
    dlon = half_km / (111.0 * max(0.1, math.cos(math.radians(lat))))
    x0, y0 = _lon_lat_to_tile(lon - dlon, lat + dlat, z)
    x1, y1 = _lon_lat_to_tile(lon + dlon, lat - dlat, z)
    return [
        (x, y)
        for x in range(min(x0, x1), max(x0, x1) + 1)
        for y in range(min(y0, y1), max(y0, y1) + 1)
    ]


def _all_hotspot_points() -> List[Tuple[float, float]]:
    points = [(round(HOTSPOT_LAT, 4), round(HOTSPOT_LON, 4))]
    with _dynamic_hotspots_lock:
        points.extend((round(lat, 4), round(lon, 4)) for lat, lon in _dynamic_hotspots)
    return list(dict.fromkeys(points))


def _lon_lat_to_tile(lon: float, lat: float, z: int) -> Tuple[int, int]:
    tile_count = 2**z
    clamped_lat = max(-85.05112878, min(85.05112878, lat))
    lat_rad = math.radians(clamped_lat)
    x = int(math.floor((lon + 180.0) / 360.0 * tile_count))
    y = int(math.floor((1.0 - math.log(math.tan(lat_rad) + 1.0 / math.cos(lat_rad)) / math.pi) / 2.0 * tile_count))
    return (
        min(max(x, 0), tile_count - 1),
        min(max(y, 0), tile_count - 1),
    )


def _download_frames(include_history: bool) -> List[RadarFrame]:
    if DWD_RADAR_RENDER_MODE == "wms":
        return _download_wms_frames(include_history=include_history)

    latest = _download_archive(DWD_RV_URL)
    latest_frames = _extract_frames(latest)
    if DWD_RADAR_RENDER_MODE in {"native", "hybrid", "raw"}:
        latest_frames = [frame for frame in latest_frames if _is_native_timeline_frame(frame)]
    latest_base = latest_frames[0].time if latest_frames else datetime.now(timezone.utc)

    observed_by_time: Dict[datetime, RadarFrame] = {}
    if include_history:
        for url in _recent_archive_urls(latest_base):
            try:
                frames = _extract_frames(_download_archive(url))
            except Exception as error:
                logger.warning("skipping %s: %s", url, error)
                continue
            for frame in frames:
                if (
                    _is_native_timeline_frame(frame)
                    and not frame.is_forecast
                    and frame.time >= latest_base - timedelta(hours=PAST_HOURS)
                ):
                    observed_by_time[frame.time] = frame

    for frame in latest_frames:
        if not frame.is_forecast:
            observed_by_time[frame.time] = frame

    combined = sorted(observed_by_time.values(), key=lambda item: item.time)
    combined.extend(frame for frame in latest_frames if frame.is_forecast)
    combined = _dedupe_and_sort_frames(combined)

    if DWD_RADAR_RENDER_MODE in {"native", "hybrid", "raw"}:
        try:
            blank = Image.new("RGBA", (1, 1), (0, 0, 0, 0))
            after = max((frame.time for frame in combined), default=latest_base)
            icon_raw = _download_icon_raw_frames(after=after)
            if icon_raw:
                combined.extend(icon_raw)
                wms_after = max((frame.time for frame in icon_raw), default=after)
                combined.extend(
                    _download_icon_wms_frames(
                        _download_wms_capabilities(),
                        after=wms_after,
                        blank=blank,
                        until=after + timedelta(hours=ICON_FORECAST_HOURS),
                    )
                )
            else:
                combined.extend(_download_icon_wms_frames(_download_wms_capabilities(), after=after, blank=blank))
            combined = _dedupe_and_sort_frames(combined)
        except Exception as error:
            logger.warning("ICON extension unavailable: %s", error)

    if not combined:
        raise RuntimeError("DWD radar archive contained no usable frames")
    return combined


def _download_icon_raw_frames(after: datetime) -> List[RadarFrame]:
    if ICON_RAW_MODE not in {"auto", "raw", "raw-grib", "grib"}:
        return []
    if not _icon_raw_decoder_available():
        _metric_increment("iconRawFailures")
        _metric_set("lastIconRawError", "ecCodes decoder unavailable")
        return []

    try:
        index = _latest_icon_raw_index("tot_prec")
        if index is None:
            raise RuntimeError("no ICON-EU TOT_PREC run found")
        run_hour, reference_time, total_files = index

        with _icon_raw_cache_lock:
            cached_reference = _icon_raw_cache.get("referenceTime")
            cached_frames = list(_icon_raw_cache.get("frames") or [])
            if cached_reference == reference_time and cached_frames:
                frames = [frame for frame in cached_frames if frame.time > after]
                _metric_increment("iconRawCacheHits")
                _metric_set("lastIconRawRun", f"{run_hour}/{reference_time.isoformat()}")
                _metric_set("lastIconRawError", None)
                _metric_set("iconRawFrames", len(frames))
                return frames

        snow_gsp = _icon_raw_index_for_run("snow_gsp", run_hour)
        snow_con = _icon_raw_index_for_run("snow_con", run_hour)
        cache: Dict[str, np.ndarray] = {}

        frames: List[RadarFrame] = []
        max_step = min(ICON_RAW_FORECAST_HOURS, max(total_files.keys(), default=0))
        step_delta = max(1, ICON_RAW_STEP_HOURS)
        start_step = 1
        for step in range(start_step, max_step + 1, step_delta):
            if len(frames) >= ICON_RAW_MAX_FRAMES:
                break
            if step not in total_files or step - 1 not in total_files:
                continue
            total_now = _icon_raw_values(total_files[step], cache)
            total_prev = _icon_raw_values(total_files[step - 1], cache)
            intensity = np.maximum(total_now - total_prev, 0.0)

            snow_intensity = np.zeros_like(intensity)
            for snow_index in (snow_gsp, snow_con):
                if step in snow_index and step - 1 in snow_index:
                    snow_intensity += np.maximum(
                        _icon_raw_values(snow_index[step], cache) - _icon_raw_values(snow_index[step - 1], cache),
                        0.0,
                    )

            precipitation_type = _precipitation_type(intensity, snow_intensity)
            frame_time = reference_time + timedelta(hours=step)
            frames.append(
                RadarFrame(
                    frame_id=f"iconraw--{reference_time.strftime('%Y%m%dT%H%M%SZ')}--{step:03d}",
                    time=frame_time,
                    is_forecast=True,
                    image=_render_icon_raw_image(intensity, snow_intensity),
                    reference_time=reference_time,
                    precipitation_type=precipitation_type,
                )
            )

        with _icon_raw_cache_lock:
            _icon_raw_cache["referenceTime"] = reference_time
            _icon_raw_cache["runHour"] = run_hour
            _icon_raw_cache["frames"] = frames
        filtered_frames = [frame for frame in frames if frame.time > after]
        _metric_set("lastIconRawRun", f"{run_hour}/{reference_time.isoformat()}")
        _metric_set("lastIconRawError", None)
        _metric_set("iconRawFrames", len(filtered_frames))
        return filtered_frames
    except Exception as error:
        _metric_increment("iconRawFailures")
        _metric_set("lastIconRawError", str(error))
        logger.warning("ICON raw unavailable: %s", error)
        return []


def _precipitation_type(intensity: np.ndarray, snow_intensity: np.ndarray) -> str:
    wet = intensity >= 0.05
    if not np.any(wet):
        return "unknown"
    snowy = wet & (snow_intensity >= 0.05)
    snow_fraction = float(np.count_nonzero(snowy)) / float(np.count_nonzero(wet))
    if snow_fraction >= 0.60:
        return "snow"
    if snow_fraction >= 0.20:
        return "mixed"
    return "rain"


def _latest_icon_raw_index(variable: str) -> Tuple[str, datetime, Dict[int, str]] | None:
    candidates: List[Tuple[datetime, str, Dict[int, str]]] = []
    diagnostics: List[Dict[str, Any]] = []
    for run_hour in ["00", "03", "06", "09", "12", "15", "18", "21"]:
        files = _icon_raw_index_for_run(variable, run_hour)
        diagnostic: Dict[str, Any] = {
            "runHour": run_hour,
            "steps": len(files),
            "maxStep": max(files.keys(), default=0),
        }
        if not files:
            diagnostics.append(diagnostic)
            continue
        reference = _icon_reference_from_url(next(iter(files.values())))
        diagnostic["referenceTime"] = reference.isoformat() if reference else None
        diagnostics.append(diagnostic)
        if reference is not None:
            candidates.append((reference, run_hour, files))
    _metric_set("lastIconRawCandidates", diagnostics)
    if not candidates:
        return None
    reference, run_hour, files = max(candidates, key=lambda item: (item[0], len(item[2])))
    return run_hour, reference, files


def _icon_raw_index_for_run(variable: str, run_hour: str) -> Dict[int, str]:
    directory = f"{ICON_RAW_BASE_URL.rstrip('/')}/{run_hour}/{variable}/"
    try:
        with urllib.request.urlopen(directory, timeout=18) as response:
            html = response.read().decode("utf-8", errors="ignore")
    except Exception as error:
        # Not fatal (a run may not be published yet), but a persistent failure
        # here silently disables forecast frames — keep it visible in logs.
        logger.debug("ICON index fetch failed for %s/%s: %s", run_hour, variable, error)
        return {}
    suffix = variable.upper()
    result: Dict[int, str] = {}
    parser = _IconRawLinkParser()
    parser.feed(html)
    for href in parser.links:
        if not href.endswith(f"_{suffix}.grib2.bz2"):
            continue
        parts = href.split("_")
        if len(parts) < 6:
            continue
        try:
            step = int(parts[5])
        except ValueError:
            continue
        result[step] = urllib.parse.urljoin(directory, href)
    return result


def _icon_reference_from_url(url: str) -> datetime | None:
    name = url.rsplit("/", 1)[-1]
    parts = name.split("_")
    if len(parts) < 5:
        return None
    try:
        return datetime.strptime(parts[4], "%Y%m%d%H").replace(tzinfo=timezone.utc)
    except ValueError:
        return None


def _icon_raw_values(url: str, cache: Dict[str, np.ndarray]) -> np.ndarray:
    if url in cache:
        return cache[url]
    from eccodes import codes_get, codes_get_array, codes_grib_new_from_file, codes_release  # type: ignore

    with urllib.request.urlopen(url, timeout=25) as response:
        compressed = response.read()
    raw = bz2.decompress(compressed)
    with tempfile.NamedTemporaryFile(suffix=".grib2") as handle:
        handle.write(raw)
        handle.flush()
        with open(handle.name, "rb") as grib_file:
            gid = codes_grib_new_from_file(grib_file)
            if gid is None:
                raise RuntimeError(f"cannot decode GRIB: {url}")
            try:
                ni = int(codes_get(gid, "Ni"))
                nj = int(codes_get(gid, "Nj"))
                values = np.asarray(codes_get_array(gid, "values"), dtype=np.float32).reshape((nj, ni))
                first_lat = float(codes_get(gid, "latitudeOfFirstGridPointInDegrees"))
                last_lat = float(codes_get(gid, "latitudeOfLastGridPointInDegrees"))
                first_lon = float(codes_get(gid, "longitudeOfFirstGridPointInDegrees"))
                last_lon = float(codes_get(gid, "longitudeOfLastGridPointInDegrees"))
            finally:
                codes_release(gid)

    cache[url] = _crop_regular_lat_lon(values, first_lat, last_lat, first_lon, last_lon)
    return cache[url]


def _crop_regular_lat_lon(values: np.ndarray, first_lat: float, last_lat: float, first_lon: float, last_lon: float) -> np.ndarray:
    lats = np.linspace(first_lat, last_lat, values.shape[0], dtype=np.float32)
    if first_lon > last_lon:
        span = (last_lon + 360.0) - first_lon
        lons = (first_lon + np.linspace(0.0, span, values.shape[1], dtype=np.float32)) % 360.0
    else:
        lons = np.linspace(first_lon, last_lon, values.shape[1], dtype=np.float32)
    lons = ((lons + 180.0) % 360.0) - 180.0
    lon_order = np.argsort(lons)
    lat_order = np.argsort(lats)[::-1]
    lons = lons[lon_order]
    lats = lats[lat_order]
    ordered_values = values[np.ix_(lat_order, lon_order)]
    west, south, east, north = RADAR_BBOX
    lon_mask = (lons >= west) & (lons <= east)
    lat_mask = (lats >= south) & (lats <= north)
    if not np.any(lon_mask) or not np.any(lat_mask):
        raise RuntimeError("ICON grid does not intersect radar bbox")
    cropped = ordered_values[np.ix_(lat_mask, lon_mask)]
    return np.nan_to_num(cropped, nan=0.0, posinf=0.0, neginf=0.0)


def _render_icon_raw_image(intensity: np.ndarray, snow_intensity: np.ndarray) -> Image.Image:
    rain = np.maximum(intensity - snow_intensity, 0.0)
    rgba = np.zeros((intensity.shape[0], intensity.shape[1], 4), dtype=np.uint8)
    for lower, upper, color in RAIN_COLOR_STEPS:
        _paint_range(rgba, rain, lower, upper, color)
    _paint_range(rgba, snow_intensity, 0.01, 0.5, (255, 255, 255, 145))
    _paint_range(rgba, snow_intensity, 0.5, 2.0, (220, 238, 255, 180))
    _paint_range(rgba, snow_intensity, 2.0, 9999.0, (186, 206, 255, 220))
    image = Image.fromarray(rgba, "RGBA")
    return image.resize((GRID_WIDTH, GRID_HEIGHT), Image.Resampling.BILINEAR)


def _download_wms_frames(include_history: bool) -> List[RadarFrame]:
    capabilities = _download_wms_capabilities()
    start, end, step = _wms_time_range(capabilities, DWD_WMS_LAYER)
    reference = _wms_reference_time(capabilities, DWD_WMS_LAYER) or min(datetime.now(timezone.utc), end)
    reference = _snap_to_range(reference, start, end, step)

    if include_history or PAST_HOURS > 0:
        lower = max(start, reference - timedelta(hours=PAST_HOURS))
    else:
        lower = reference

    frames: List[RadarFrame] = []
    current = _snap_to_range(lower, start, end, step)
    blank = Image.new("RGBA", (1, 1), (0, 0, 0, 0))
    while current <= end:
        if current >= lower:
            frame_id = _wms_frame_id(DWD_WMS_LAYER, current)
            frames.append(
                RadarFrame(
                    frame_id=frame_id,
                    time=current,
                    is_forecast=current > reference,
                    image=blank,
                    layer_name=DWD_WMS_LAYER,
                )
            )
        current += step

    frames.extend(_download_icon_wms_frames(capabilities, after=end, blank=blank))

    if not frames:
        raise RuntimeError("DWD WMS capabilities contained no usable radar times")
    return _dedupe_and_sort_frames(frames)


def _download_icon_wms_frames(root: ET.Element, after: datetime, blank: Image.Image, until: datetime | None = None) -> List[RadarFrame]:
    layer_name = _best_icon_layer(root)
    if not layer_name:
        return []
    try:
        start, end, step = _wms_time_range(root, layer_name)
    except Exception as error:
        logger.warning("ICON timeline unavailable for %s: %s", layer_name, error)
        return []
    reference_time = _wms_reference_time(root, layer_name)

    lower = max(start, after + timedelta(minutes=30))
    upper = min(end, until or (after + timedelta(hours=ICON_FORECAST_HOURS)))
    if lower > upper:
        return []

    frames: List[RadarFrame] = []
    current = _snap_to_range(lower, start, end, step)
    while current <= upper:
        if current >= lower:
            frames.append(
                RadarFrame(
                    frame_id=_wms_frame_id(layer_name, current, reference_time),
                    time=current,
                    is_forecast=True,
                    image=blank,
                    layer_name=layer_name,
                    reference_time=reference_time,
                )
            )
        current += step
    _metric_set("iconWmsFrames", len(frames))
    return frames


def _dedupe_and_sort_frames(frames: List[RadarFrame]) -> List[RadarFrame]:
    seen: set[Tuple[str, datetime]] = set()
    seen_times: set[datetime] = set()
    result: List[RadarFrame] = []
    for frame in sorted(frames, key=lambda item: (item.time, item.is_forecast, item.layer_name or "")):
        key = (_frame_source(frame), frame.time)
        if key in seen:
            continue
        if frame.frame_id.startswith("iconraw--") and frame.time in seen_times:
            continue
        seen.add(key)
        seen_times.add(frame.time)
        result.append(frame)
    return result


def _download_wms_capabilities() -> ET.Element:
    params = {
        "SERVICE": "WMS",
        "VERSION": "1.3.0",
        "REQUEST": "GetCapabilities",
    }
    url = f"{DWD_WMS_URL}?{urllib.parse.urlencode(params)}"
    with urllib.request.urlopen(url, timeout=25) as response:
        return ET.fromstring(response.read())


def _wms_layer(root: ET.Element, layer_name: str) -> ET.Element:
    for layer in root.iter():
        if _xml_local_name(layer.tag) != "Layer":
            continue
        for child in layer:
            if _xml_local_name(child.tag) == "Name" and (child.text or "").strip() == layer_name:
                return layer
    raise RuntimeError(f"DWD WMS layer not found: {layer_name}")


def _best_icon_layer(root: ET.Element) -> str | None:
    available: set[str] = set()
    for layer in root.iter():
        if _xml_local_name(layer.tag) != "Layer":
            continue
        for child in layer:
            if _xml_local_name(child.tag) == "Name" and child.text:
                available.add(child.text.strip())
    for layer_name in ICON_PRECIP_LAYERS:
        if layer_name in available:
            return layer_name
    return None


def _wms_time_range(root: ET.Element, layer_name: str) -> Tuple[datetime, datetime, timedelta]:
    layer = _wms_layer(root, layer_name)
    for child in layer:
        if _xml_local_name(child.tag) == "Dimension" and child.attrib.get("name") == "time":
            value = (child.text or "").strip()
            parts = value.split("/")
            if len(parts) == 3:
                start = _parse_wms_datetime(parts[0])
                end = _parse_wms_datetime(parts[1])
                step = _parse_wms_duration(parts[2])
                return start, end, step
            times = [_parse_wms_datetime(item.strip()) for item in value.split(",") if item.strip()]
            if times:
                step = times[1] - times[0] if len(times) > 1 else timedelta(minutes=5)
                return min(times), max(times), step
    raise RuntimeError(f"DWD WMS layer has no time dimension: {layer_name}")


def _wms_reference_time(root: ET.Element, layer_name: str) -> datetime | None:
    layer = _wms_layer(root, layer_name)
    for child in layer:
        if _xml_local_name(child.tag) == "Dimension" and child.attrib.get("name") == "REFERENCE_TIME":
            default = child.attrib.get("default")
            if default:
                return _parse_wms_datetime(default)
    return None


def _parse_wms_datetime(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(timezone.utc)


def _parse_wms_duration(value: str) -> timedelta:
    if value == "PT5M":
        return timedelta(minutes=5)
    if value.startswith("PT") and value.endswith("M"):
        return timedelta(minutes=int(value[2:-1]))
    if value.startswith("PT") and value.endswith("H"):
        return timedelta(hours=int(value[2:-1]))
    raise RuntimeError(f"Unsupported WMS time step: {value}")


def _snap_to_range(value: datetime, start: datetime, end: datetime, step: timedelta) -> datetime:
    if value <= start:
        return start
    if value >= end:
        return end
    step_seconds = max(1, int(step.total_seconds()))
    offset = int((value - start).total_seconds()) // step_seconds * step_seconds
    return start + timedelta(seconds=offset)


def _wms_frame_id(layer_name: str, value: datetime, reference_time: datetime | None = None) -> str:
    layer_token = urllib.parse.quote(layer_name, safe="")
    value_token = value.strftime("%Y%m%dT%H%M%SZ")
    if reference_time is None:
        return f"wms--{layer_token}--{value_token}"
    return f"wms--{layer_token}--{value_token}--ref{reference_time.strftime('%Y%m%dT%H%M%SZ')}"


def _wms_layer_and_time_from_frame(frame: RadarFrame) -> Tuple[str, datetime]:
    if frame.layer_name:
        return frame.layer_name, frame.time
    parts = frame.frame_id.split("--", 2)
    if len(parts) == 3 and parts[0] == "wms":
        return urllib.parse.unquote(parts[1]), datetime.strptime(parts[2], "%Y%m%dT%H%M%SZ").replace(tzinfo=timezone.utc)
    return DWD_WMS_LAYER, frame.time


def _xml_local_name(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


def _download_archive(url: str) -> bytes:
    with urllib.request.urlopen(url, timeout=25) as response:
        return response.read()


def _extract_frames(archive: bytes) -> List[RadarFrame]:
    frames: List[RadarFrame] = []
    with tarfile.open(fileobj=io.BytesIO(bz2.decompress(archive)), mode="r:") as tar:
        for member in sorted(tar.getmembers(), key=lambda item: item.name):
            if not member.isfile():
                continue
            extracted = tar.extractfile(member)
            if extracted is None:
                continue
            raw = extracted.read()
            frame = _parse_frame(member.name, raw)
            if frame is not None:
                frames.append(frame)

    return frames


def _recent_archive_urls(reference: datetime) -> List[str]:
    try:
        with urllib.request.urlopen(DWD_RV_INDEX_URL, timeout=15) as response:
            html = response.read().decode("utf-8", errors="ignore")
    except Exception as error:
        logger.warning("index unavailable, using latest only: %s", error)
        return [DWD_RV_URL]

    parser = _DwdArchiveLinkParser()
    parser.feed(html)
    lower_bound = reference - timedelta(hours=PAST_HOURS)
    selected: List[Tuple[datetime, str]] = []
    for href in parser.links:
        if not href.startswith("DE1200_RV") or not href.endswith(".tar.bz2") or "LATEST" in href:
            continue
        stamp = _archive_time_from_name(href)
        if stamp is None:
            continue
        if lower_bound <= stamp <= reference:
            selected.append((stamp, DWD_RV_INDEX_URL + href))

    stepped = [
        item
        for item in selected
        if item[0].minute % max(5, PAST_STEP_MINUTES) == 0
    ]
    selected = stepped or selected
    selected.sort(key=lambda item: item[0])
    max_archives = max(1, int(PAST_HOURS * 60 / max(5, PAST_STEP_MINUTES)) + 1)
    return [url for _, url in selected[-max_archives:]]


def _archive_time_from_name(name: str) -> datetime | None:
    try:
        stamp = name.split("_")[1][2:12]
        return datetime.strptime(stamp, "%y%m%d%H%M").replace(tzinfo=timezone.utc)
    except (IndexError, ValueError):
        return None


class _DwdArchiveLinkParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.links: List[str] = []

    def handle_starttag(self, tag: str, attrs: List[Tuple[str, Optional[str]]]) -> None:
        if tag != "a":
            return
        for key, value in attrs:
            if key == "href" and value:
                self.links.append(value)


class _IconRawLinkParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.links: List[str] = []

    def handle_starttag(self, tag: str, attrs: List[Tuple[str, Optional[str]]]) -> None:
        if tag != "a":
            return
        for key, value in attrs:
            if key == "href" and value:
                self.links.append(value)


def _parse_frame(name: str, raw: bytes) -> RadarFrame | None:
    try:
        header_end = raw.index(b"\x03") + 1
    except ValueError:
        return None

    payload = raw[header_end:]
    expected = GRID_WIDTH * GRID_HEIGHT * 2
    if len(payload) < expected:
        return None

    grid = np.frombuffer(payload[:expected], dtype="<u2").reshape((GRID_HEIGHT, GRID_WIDTH))
    image = _render_radar_image(grid)
    time_value, is_forecast = _time_from_name(name)
    return RadarFrame(frame_id=name, time=time_value, is_forecast=is_forecast, image=image)


def _time_from_name(name: str) -> Tuple[datetime, bool]:
    # Example: DE1200_RV2606290300_045
    parts = name.split("_")
    stamp = parts[1][2:] if len(parts) >= 2 and parts[1].startswith("RV") else "7001010000"
    offset = int(parts[2]) if len(parts) >= 3 and parts[2].isdigit() else 0
    base = datetime.strptime(stamp, "%y%m%d%H%M").replace(tzinfo=timezone.utc)
    return base + timedelta(minutes=offset), offset > 0


def _is_native_timeline_frame(frame: RadarFrame) -> bool:
    if NATIVE_FRAME_STEP_MINUTES <= 5:
        return True
    parts = frame.frame_id.split("_")
    try:
        offset = int(parts[2]) if len(parts) >= 3 and parts[2].isdigit() else 0
    except (IndexError, ValueError):
        return True
    return offset % NATIVE_FRAME_STEP_MINUTES == 0


def _render_radar_image(grid: np.ndarray) -> Image.Image:
    raw_values = grid.astype(np.uint16)
    values = raw_values & np.uint16(0x0FFF)

    positive = values[values > 0]
    nodata_value = int(np.bincount(positive).argmax()) if positive.size else -1
    valid = (values > 0) & (values != nodata_value) & (values < 4090)

    rgba = np.zeros((GRID_HEIGHT, GRID_WIDTH, 4), dtype=np.uint8)
    intensity = np.zeros_like(values, dtype=np.float32)
    intensity[valid] = values[valid].astype(np.float32) / 10.0

    for lower, upper, color in RAIN_COLOR_STEPS:
        _paint_range(rgba, intensity, lower, upper, color)

    return Image.fromarray(rgba, "RGBA")


def _paint_range(rgba: np.ndarray, intensity: np.ndarray, lower: float, upper: float, color: Tuple[int, int, int, int]) -> None:
    mask = (intensity >= lower) & (intensity < upper)
    rgba[mask] = color


def _render_tile(image: Image.Image, z: int, x: int, y: int) -> bytes:
    tile_bounds = _tile_lon_lat_bounds(z, x, y)
    intersection = _intersection(tile_bounds, RADAR_BBOX)
    if intersection is None:
        return _empty_tile()

    west, south, east, north = intersection
    source = _source_rect(west, south, east, north)
    if source[2] <= source[0] or source[3] <= source[1]:
        return _empty_tile()

    tile_west, tile_south, tile_east, tile_north = tile_bounds
    target = (
        int(round((west - tile_west) / (tile_east - tile_west) * TILE_SIZE)),
        int(round((tile_north - north) / (tile_north - tile_south) * TILE_SIZE)),
        int(round((east - tile_west) / (tile_east - tile_west) * TILE_SIZE)),
        int(round((tile_north - south) / (tile_north - tile_south) * TILE_SIZE)),
    )

    scale = TILE_RENDER_SCALE
    output_size = TILE_SIZE * scale
    out = Image.new("RGBA", (output_size, output_size), (0, 0, 0, 0))
    scaled_target = tuple(value * scale for value in target)
    crop = image.crop(source)
    crop = crop.resize(
        (
            max(1, scaled_target[2] - scaled_target[0]),
            max(1, scaled_target[3] - scaled_target[1]),
        ),
        Image.Resampling.BILINEAR,
    )
    out.alpha_composite(crop, dest=(scaled_target[0], scaled_target[1]))

    if scale > 1:
        # BILINEAR is visually equivalent to LANCZOS for a 2x->1x downscale of
        # flat color classes but roughly half the CPU cost — matters because
        # every uncached tile is rendered on demand.
        out = out.resize((TILE_SIZE, TILE_SIZE), Image.Resampling.BILINEAR)

    buffer = io.BytesIO()
    out.save(buffer, format="PNG", optimize=False, compress_level=1)
    return buffer.getvalue()


def _render_wms_tile(frame: RadarFrame, z: int, x: int, y: int) -> bytes:
    if not _tile_intersects_wms_coverage(z, x, y):
        return _empty_tile()

    layer_name, time_value = _wms_layer_and_time_from_frame(frame)
    west, south, east, north = _tile_web_mercator_bounds(z, x, y)
    params = {
        "SERVICE": "WMS",
        "VERSION": "1.3.0",
        "REQUEST": "GetMap",
        "LAYERS": layer_name,
        "STYLES": "",
        "FORMAT": "image/png",
        "TRANSPARENT": "true",
        "CRS": "EPSG:3857",
        "BBOX": f"{west:.6f},{south:.6f},{east:.6f},{north:.6f}",
        "WIDTH": str(TILE_SIZE),
        "HEIGHT": str(TILE_SIZE),
        "TIME": time_value.strftime("%Y-%m-%dT%H:%M:%S.000Z"),
    }
    if frame.reference_time is not None:
        params["DIM_REFERENCE_TIME"] = frame.reference_time.strftime("%Y-%m-%dT%H:%M:%S.000Z")
    url = f"{DWD_WMS_URL}?{urllib.parse.urlencode(params)}"
    try:
        request = urllib.request.Request(url, headers={"User-Agent": "WeatherMat RadarProxy"})
        with urllib.request.urlopen(request, timeout=20) as response:
            data = response.read()
            content_type = response.headers.get("Content-Type", "")
            if response.status == 200 and ("image/png" in content_type or data.startswith(b"\x89PNG")):
                if ICON_WMS_RECOLOR and layer_name != DWD_WMS_LAYER:
                    return _recolor_precip_tile(data)
                return data
    except Exception as error:
        _metric_increment("wmsTileFailures")
        logger.warning("WMS tile failed z=%s x=%s y=%s: %s", z, x, y, error)
    return _empty_tile()


def _recolor_precip_tile(data: bytes) -> bytes:
    try:
        image = Image.open(io.BytesIO(data)).convert("RGBA")
    except Exception:
        return data

    arr = np.array(image, dtype=np.uint8)
    alpha = arr[:, :, 3].astype(np.uint8)
    rgb = arr[:, :, :3].astype(np.float32)
    visible = alpha > 8
    if not np.any(visible):
        return data

    maxc = rgb.max(axis=2)
    minc = rgb.min(axis=2)
    chroma = maxc - minc
    saturated = visible & (chroma > 18)
    if not np.any(saturated):
        return data

    r = rgb[:, :, 0]
    g = rgb[:, :, 1]
    b = rgb[:, :, 2]
    hue = np.zeros_like(maxc)

    red_is_max = (maxc == r) & (chroma > 0)
    green_is_max = (maxc == g) & (chroma > 0)
    blue_is_max = (maxc == b) & (chroma > 0)
    hue[red_is_max] = ((g[red_is_max] - b[red_is_max]) / chroma[red_is_max]) % 6.0
    hue[green_is_max] = ((b[green_is_max] - r[green_is_max]) / chroma[green_is_max]) + 2.0
    hue[blue_is_max] = ((r[blue_is_max] - g[blue_is_max]) / chroma[blue_is_max]) + 4.0
    hue *= 60.0

    out = np.zeros_like(arr)
    light = saturated & (hue >= 165) & (hue < 250)
    green = saturated & (hue >= 75) & (hue < 165)
    yellow = saturated & (hue >= 45) & (hue < 75)
    orange = saturated & (hue >= 18) & (hue < 45)
    red = saturated & ((hue < 18) | (hue >= 300))
    purple = saturated & (hue >= 250) & (hue < 300)

    out[light] = RAIN_COLOR_STEPS[0][2]
    out[green] = RAIN_COLOR_STEPS[1][2]
    out[yellow] = RAIN_COLOR_STEPS[2][2]
    out[orange] = RAIN_COLOR_STEPS[3][2]
    out[red] = RAIN_COLOR_STEPS[4][2]
    out[purple] = RAIN_COLOR_STEPS[5][2]

    buffer = io.BytesIO()
    Image.fromarray(out, "RGBA").save(buffer, format="PNG", optimize=False, compress_level=1)
    return buffer.getvalue()


def _tile_web_mercator_bounds(z: int, x: int, y: int) -> Tuple[float, float, float, float]:
    tile_count = 2**z
    tile_size = (WEB_MERCATOR_LIMIT * 2.0) / tile_count
    west = -WEB_MERCATOR_LIMIT + x * tile_size
    east = west + tile_size
    north = WEB_MERCATOR_LIMIT - y * tile_size
    south = north - tile_size
    return west, south, east, north


def _tile_intersects_wms_coverage(z: int, x: int, y: int) -> bool:
    return _intersection(_tile_lon_lat_bounds(z, x, y), RADAR_BBOX) is not None


def _source_rect(west: float, south: float, east: float, north: float) -> Tuple[int, int, int, int]:
    bbox_west, bbox_south, bbox_east, bbox_north = RADAR_BBOX
    left = int(math.floor((west - bbox_west) / (bbox_east - bbox_west) * GRID_WIDTH))
    right = int(math.ceil((east - bbox_west) / (bbox_east - bbox_west) * GRID_WIDTH))
    top = int(math.floor((bbox_north - north) / (bbox_north - bbox_south) * GRID_HEIGHT))
    bottom = int(math.ceil((bbox_north - south) / (bbox_north - bbox_south) * GRID_HEIGHT))
    return (
        max(0, min(GRID_WIDTH, left)),
        max(0, min(GRID_HEIGHT, top)),
        max(0, min(GRID_WIDTH, right)),
        max(0, min(GRID_HEIGHT, bottom)),
    )


def _tile_lon_lat_bounds(z: int, x: int, y: int) -> Tuple[float, float, float, float]:
    west, north = _tile_to_lon_lat(x, y, z)
    east, south = _tile_to_lon_lat(x + 1, y + 1, z)
    return west, south, east, north


def _tile_to_lon_lat(x: int, y: int, z: int) -> Tuple[float, float]:
    n = 2.0**z
    lon = x / n * 360.0 - 180.0
    lat_rad = math.atan(math.sinh(math.pi * (1 - 2 * y / n)))
    lat = math.degrees(lat_rad)
    return lon, lat


def _intersection(a: Tuple[float, float, float, float], b: Tuple[float, float, float, float]) -> Tuple[float, float, float, float] | None:
    west = max(a[0], b[0])
    south = max(a[1], b[1])
    east = min(a[2], b[2])
    north = min(a[3], b[3])
    if west >= east or south >= north:
        return None
    return west, south, east, north


def _empty_tile() -> bytes:
    global _transparent_tile
    if _transparent_tile is None:
        image = Image.new("RGBA", (TILE_SIZE, TILE_SIZE), (0, 0, 0, 0))
        buffer = io.BytesIO()
        image.save(buffer, format="PNG", optimize=False, compress_level=1)
        _transparent_tile = buffer.getvalue()
    return _transparent_tile
