from __future__ import annotations

import bz2
import io
import math
import os
import tarfile
import time
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from html.parser import HTMLParser
from typing import Dict, List, Optional, Tuple

import numpy as np
from fastapi import FastAPI, HTTPException, Response
from PIL import Image


DWD_RV_URL = os.environ.get(
    "DWD_RV_URL",
    "https://opendata.dwd.de/weather/radar/composite/rv/DE1200_RV_LATEST.tar.bz2",
)
DWD_RV_INDEX_URL = os.environ.get(
    "DWD_RV_INDEX_URL",
    "https://opendata.dwd.de/weather/radar/composite/rv/",
)
CACHE_SECONDS = int(os.environ.get("DWD_RADAR_CACHE_SECONDS", "240"))
PAST_HOURS = int(os.environ.get("DWD_RADAR_PAST_HOURS", "24"))
PAST_STEP_MINUTES = int(os.environ.get("DWD_RADAR_PAST_STEP_MINUTES", "15"))
TILE_SIZE = 512
GRID_WIDTH = 1200
GRID_HEIGHT = 1100

# Practical coverage of the DE1200 composite for a MapKit overlay. The official
# RADOLAN projection is polar stereographic; for app-sized radar inspection this
# georeferenced crop keeps Germany aligned closely enough while the proxy stays
# lightweight and deployable.
RADAR_BBOX = (
    float(os.environ.get("DWD_RADAR_WEST", "1.5")),
    float(os.environ.get("DWD_RADAR_SOUTH", "45.2")),
    float(os.environ.get("DWD_RADAR_EAST", "16.8")),
    float(os.environ.get("DWD_RADAR_NORTH", "55.6")),
)


@dataclass(frozen=True)
class RadarFrame:
    frame_id: str
    time: datetime
    is_forecast: bool
    image: Image.Image


@dataclass
class RadarCache:
    loaded_at: float
    frames: List[RadarFrame]
    tile_cache: Dict[Tuple[str, int, int, int], bytes]


app = FastAPI(title="WeatherMat DWD Radar Proxy")
_cache: RadarCache | None = None
_transparent_tile: bytes | None = None


@app.get("/health")
def health() -> dict:
    cache = _ensure_cache()
    return {"ok": True, "frames": len(cache.frames), "loadedAt": cache.loaded_at}


@app.get("/timeline.json")
def timeline() -> dict:
    cache = _ensure_cache()
    return {
        "source": "DWD OpenData RV",
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "frames": [
            {
                "id": frame.frame_id,
                "time": frame.time.isoformat(),
                "isForecast": frame.is_forecast,
            }
            for frame in cache.frames
        ],
    }


@app.get("/tiles/{frame_id}/{z}/{x}/{y}.png")
def tile(frame_id: str, z: int, x: int, y: int) -> Response:
    cache = _ensure_cache()
    frame = next((item for item in cache.frames if item.frame_id == frame_id), None)
    if frame is None:
        raise HTTPException(status_code=404, detail="Unknown radar frame")

    key = (frame_id, z, x, y)
    data = cache.tile_cache.get(key)
    if data is None:
        data = _render_tile(frame.image, z, x, y)
        if len(cache.tile_cache) > 8000:
            cache.tile_cache.clear()
        cache.tile_cache[key] = data
    return Response(content=data, media_type="image/png", headers={"Cache-Control": "public, max-age=240"})


def _ensure_cache() -> RadarCache:
    global _cache
    now = time.time()
    if _cache is None or now - _cache.loaded_at > CACHE_SECONDS:
        _cache = RadarCache(loaded_at=now, frames=_download_frames(), tile_cache={})
    return _cache


def _download_frames() -> List[RadarFrame]:
    latest = _download_archive(DWD_RV_URL)
    latest_frames = _extract_frames(latest)
    latest_base = latest_frames[0].time if latest_frames else datetime.now(timezone.utc)

    observed_by_time: Dict[datetime, RadarFrame] = {}
    for url in _recent_archive_urls(latest_base):
        try:
            frames = _extract_frames(_download_archive(url))
        except Exception as error:
            print(f"[DWD] skipping {url}: {error}")
            continue
        for frame in frames:
            if not frame.is_forecast and frame.time >= latest_base - timedelta(hours=PAST_HOURS):
                observed_by_time[frame.time] = frame

    for frame in latest_frames:
        if not frame.is_forecast:
            observed_by_time[frame.time] = frame

    combined = sorted(observed_by_time.values(), key=lambda item: item.time)
    combined.extend(frame for frame in latest_frames if frame.is_forecast)
    if not combined:
        raise RuntimeError("DWD radar archive contained no usable frames")
    return combined


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
        print(f"[DWD] index unavailable, using latest only: {error}")
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


def _render_radar_image(grid: np.ndarray) -> Image.Image:
    raw_values = grid.astype(np.uint16)
    values = raw_values & np.uint16(0x0FFF)

    positive = values[values > 0]
    nodata_value = int(np.bincount(positive).argmax()) if positive.size else -1
    valid = (values > 0) & (raw_values != nodata_value) & (values < 4090)

    rgba = np.zeros((GRID_HEIGHT, GRID_WIDTH, 4), dtype=np.uint8)
    intensity = np.zeros_like(values, dtype=np.float32)
    intensity[valid] = values[valid].astype(np.float32) / 10.0

    _paint_range(rgba, intensity, 0.01, 0.4, (0, 210, 195, 140))
    _paint_range(rgba, intensity, 0.4, 1.0, (20, 175, 80, 165))
    _paint_range(rgba, intensity, 1.0, 2.5, (245, 220, 35, 185))
    _paint_range(rgba, intensity, 2.5, 6.0, (255, 140, 25, 205))
    _paint_range(rgba, intensity, 6.0, 9999.0, (225, 35, 30, 225))

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

    out = Image.new("RGBA", (TILE_SIZE, TILE_SIZE), (0, 0, 0, 0))
    crop = image.crop(source)
    crop = crop.resize((max(1, target[2] - target[0]), max(1, target[3] - target[1])), Image.Resampling.BILINEAR)
    out.alpha_composite(crop, dest=(target[0], target[1]))

    buffer = io.BytesIO()
    out.save(buffer, format="PNG", optimize=True)
    return buffer.getvalue()


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
        image.save(buffer, format="PNG", optimize=True)
        _transparent_tile = buffer.getvalue()
    return _transparent_tile
