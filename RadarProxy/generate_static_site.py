from __future__ import annotations

import json
import os
import shutil
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable, Tuple

from app import RADAR_BBOX, _download_frames, _render_tile, _tile_lon_lat_bounds


OUTPUT_DIR = Path(os.environ.get("STATIC_RADAR_OUTPUT_DIR", "site"))
MIN_ZOOM = int(os.environ.get("STATIC_TILE_MIN_Z", "4"))
MAX_ZOOM = int(os.environ.get("STATIC_TILE_MAX_Z", "8"))


def main() -> None:
    frames = _download_frames()
    if OUTPUT_DIR.exists():
        shutil.rmtree(OUTPUT_DIR)
    (OUTPUT_DIR / "tiles").mkdir(parents=True, exist_ok=True)

    timeline = {
        "source": "DWD OpenData RV static",
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "tileMinZoom": MIN_ZOOM,
        "tileMaxZoom": MAX_ZOOM,
        "frames": [
            {
                "id": frame.frame_id,
                "time": frame.time.isoformat(),
                "isForecast": frame.is_forecast,
            }
            for frame in frames
        ],
    }

    (OUTPUT_DIR / "timeline.json").write_text(json.dumps(timeline, separators=(",", ":")), encoding="utf-8")
    (OUTPUT_DIR / "health").write_text(
        json.dumps({"ok": True, "frames": len(frames), "generatedAt": timeline["generatedAt"]}),
        encoding="utf-8",
    )
    (OUTPUT_DIR / ".nojekyll").write_text("", encoding="utf-8")

    tile_count = 0
    for frame in frames:
        for z, x, y in _tile_paths_for_bbox(RADAR_BBOX, MIN_ZOOM, MAX_ZOOM):
            data = _render_tile(frame.image, z, x, y)
            path = OUTPUT_DIR / "tiles" / frame.frame_id / str(z) / str(x)
            path.mkdir(parents=True, exist_ok=True)
            (path / f"{y}.png").write_bytes(data)
            tile_count += 1

    print(f"Generated {len(frames)} frames and {tile_count} tiles in {OUTPUT_DIR}")


def _tile_paths_for_bbox(bbox: Tuple[float, float, float, float], min_zoom: int, max_zoom: int) -> Iterable[Tuple[int, int, int]]:
    west, south, east, north = bbox
    for z in range(min_zoom, max_zoom + 1):
        min_x, min_y = _lon_lat_to_tile(west, north, z)
        max_x, max_y = _lon_lat_to_tile(east, south, z)
        for x in range(min_x, max_x + 1):
            for y in range(min_y, max_y + 1):
                tile_bounds = _tile_lon_lat_bounds(z, x, y)
                if _intersects(tile_bounds, bbox):
                    yield z, x, y


def _lon_lat_to_tile(lon: float, lat: float, z: int) -> Tuple[int, int]:
    import math

    lat = min(max(lat, -85.05112878), 85.05112878)
    n = 2**z
    x = int((lon + 180.0) / 360.0 * n)
    lat_rad = math.radians(lat)
    y = int((1.0 - math.asinh(math.tan(lat_rad)) / math.pi) / 2.0 * n)
    return max(0, min(n - 1, x)), max(0, min(n - 1, y))


def _intersects(a: Tuple[float, float, float, float], b: Tuple[float, float, float, float]) -> bool:
    return max(a[0], b[0]) < min(a[2], b[2]) and max(a[1], b[1]) < min(a[3], b[3])


if __name__ == "__main__":
    main()
