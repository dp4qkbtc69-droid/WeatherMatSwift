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



class PushRegistrationTests(unittest.TestCase):
    def setUp(self) -> None:
        from fastapi.testclient import TestClient
        import tempfile, pathlib
        self.tmp = tempfile.NamedTemporaryFile(suffix=".json", delete=False)
        app.PUSH_STATE_PATH = pathlib.Path(self.tmp.name)
        app._push_state = {"registrations": {}, "seen": {}}
        app._push_state_loaded = True
        self.client = TestClient(app.app)
        self.headers = {"x-radar-token": "test-token"}
        self.token = "a" * 64

    def test_register_and_unregister_roundtrip(self) -> None:
        payload = {"token": self.token, "locations": [{"lat": 50.1, "lon": 9.1, "name": "Alzenau"}]}
        response = self.client.post("/push/register", json=payload, headers=self.headers)
        self.assertEqual(response.status_code, 200)
        body = response.json()
        self.assertTrue(body["ok"])
        self.assertEqual(body["registrations"], 1)
        self.assertFalse(body["pushConfigured"])

        response = self.client.post("/push/unregister", json={"token": self.token}, headers=self.headers)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["registrations"], 0)

    def test_register_requires_token(self) -> None:
        payload = {"token": self.token, "locations": []}
        response = self.client.post("/push/register", json=payload)
        self.assertEqual(response.status_code, 401)

    def test_register_rejects_invalid_coordinates(self) -> None:
        payload = {"token": self.token, "locations": [{"lat": 123.0, "lon": 9.1, "name": "kaputt"}]}
        response = self.client.post("/push/register", json=payload, headers=self.headers)
        self.assertEqual(response.status_code, 422)

    def test_poll_without_registrations_is_noop(self) -> None:
        app._poll_warnings_once()

    def test_severity_titles_cover_all_levels(self) -> None:
        for severity in ["Minor", "Moderate", "Severe", "Extreme"]:
            self.assertTrue(app._severity_title(severity).startswith("DWD"))


if __name__ == "__main__":
    unittest.main()
