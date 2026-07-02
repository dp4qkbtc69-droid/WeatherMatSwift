import os
import sys
import unittest
from datetime import datetime, timezone

import numpy as np
from PIL import Image

os.environ.setdefault("RADAR_PROXY_TOKEN", "test-token")
sys.path.insert(0, os.path.dirname(__file__))

import app  # noqa: E402


class RadarCoreTests(unittest.TestCase):
    def test_precipitation_type_uses_wet_area_fraction(self) -> None:
        intensity = np.array([[0.10, 0.20], [0.30, 0.40]])

        rain = np.zeros_like(intensity)
        self.assertEqual(app._precipitation_type(intensity, rain), "rain")

        mixed = np.array([[0.10, 0.00], [0.00, 0.00]])
        self.assertEqual(app._precipitation_type(intensity, mixed), "mixed")

        snow = np.array([[0.10, 0.10], [0.10, 0.00]])
        self.assertEqual(app._precipitation_type(intensity, snow), "snow")

    def test_precipitation_type_ignores_dry_pixels(self) -> None:
        intensity = np.array([[0.01, 0.00], [0.02, 0.04]])
        snow = np.ones_like(intensity)

        self.assertEqual(app._precipitation_type(intensity, snow), "unknown")

    def test_dedupe_prefers_observed_frame_over_icon_raw_at_same_time(self) -> None:
        time = datetime(2026, 7, 2, 10, tzinfo=timezone.utc)
        observed = self._frame("rv--20260702T100000Z", time, is_forecast=False)
        raw = self._frame("iconraw--20260702T030000Z--007", time, is_forecast=True)

        result = app._dedupe_and_sort_frames([raw, observed])

        self.assertEqual([frame.frame_id for frame in result], [observed.frame_id])

    def test_tile_math_clamps_world_bounds(self) -> None:
        self.assertEqual(app._lon_lat_to_tile(-180, 85.2, 2), (0, 0))
        self.assertEqual(app._lon_lat_to_tile(180, -85.2, 2), (3, 3))

    def _frame(self, frame_id: str, time: datetime, is_forecast: bool) -> app.RadarFrame:
        return app.RadarFrame(
            frame_id=frame_id,
            time=time,
            is_forecast=is_forecast,
            image=Image.new("RGBA", (1, 1), (0, 0, 0, 0)),
        )


if __name__ == "__main__":
    unittest.main()
