import os
import sys
import unittest
from datetime import datetime, timezone

import numpy as np
from PIL import Image

os.environ.setdefault("RADAR_PROXY_TOKEN", "test-token")
sys.path.insert(0, os.path.dirname(__file__))

import app  # noqa: E402


class EnsureCacheTests(unittest.TestCase):
    """Regression guard for the _ensure_cache deadlock: serving a stale cache
    called _schedule_refresh() while holding the non-reentrant _cache_lock,
    which hung every later timeline/tile request until restart."""

    def tearDown(self) -> None:
        app._cache = None
        app._refreshing = False

    def test_stale_cache_is_served_without_deadlock(self) -> None:
        import threading
        import time

        stale = app.RadarCache(
            loaded_at=time.time() - (app.CACHE_SECONDS + 60),
            frames=[],
            tile_cache={},
        )
        app._cache = stale
        # A refresh already "in flight" makes _schedule_refresh short-circuit
        # without spawning a network thread, isolating the lock behaviour.
        app._refreshing = True

        result: list = []

        def call() -> None:
            result.append(app._ensure_cache())

        worker = threading.Thread(target=call)
        worker.start()
        worker.join(timeout=5)

        self.assertFalse(worker.is_alive(), "_ensure_cache deadlocked on a stale cache")
        self.assertIs(result[0], stale)


class ApnsEnvironmentTests(unittest.TestCase):
    """The proxy must reach both APNs environments off one server so Xcode
    dev builds (sandbox) and TestFlight/App Store builds (production) both
    receive push."""

    def setUp(self) -> None:
        self._orig = app._apns_post
        self.calls = []

    def tearDown(self) -> None:
        app._apns_post = self._orig

    def _stub(self, mapping):
        def fake(device_token, env, **kwargs):
            self.calls.append(env)
            return mapping.get(env, "error")
        app._apns_post = fake

    def test_falls_back_to_the_other_environment(self) -> None:
        # Token is a production token; sandbox is tried first and reports bad-env.
        self._stub({"sandbox": "bad-env", "production": "ok"})
        app.APNS_USE_SANDBOX = True
        result, env = app._deliver_apns("tok", None, title="t", subtitle="", body="b",
                                        collapse_id="c", critical=False)
        self.assertEqual(result, "sent")
        self.assertEqual(env, "production")
        self.assertEqual(self.calls, ["sandbox", "production"])

    def test_uses_learned_environment_first(self) -> None:
        self._stub({"production": "ok", "sandbox": "ok"})
        result, env = app._deliver_apns("tok", "production", title="t", subtitle="", body="b",
                                        collapse_id="c", critical=False)
        self.assertEqual((result, env), ("sent", "production"))
        self.assertEqual(self.calls, ["production"])

    def test_bad_in_both_environments_drops_token(self) -> None:
        self._stub({"sandbox": "bad-env", "production": "bad-env"})
        result, env = app._deliver_apns("tok", None, title="t", subtitle="", body="b",
                                        collapse_id="c", critical=False)
        self.assertEqual(result, "drop")
        self.assertIsNone(env)


class PaletteSyncTests(unittest.TestCase):
    """Guards the manual color sync between server (RAIN_COLOR_STEPS) and the
    iOS legend (RadarLegendStep.steps). Fails in CI if they drift apart."""

    def test_legend_hex_matches_server_rgb(self) -> None:
        import re
        swift_path = os.path.join(
            os.path.dirname(__file__), "..", "WeatherMat", "Views", "Weather", "Radar", "RadarWidgets.swift"
        )
        if not os.path.exists(swift_path):
            self.skipTest("iOS legend source not available in this checkout")
        source = open(swift_path, encoding="utf-8").read()
        block = source.split("static let steps")[1].split("]")[0]
        hexes = re.findall(r'Color\(hex:\s*"#([0-9a-fA-F]{6})"\)', block)
        legend_rgb = [tuple(int(h[i:i + 2], 16) for i in (0, 2, 4)) for h in hexes]
        server_rgb = [color[:3] for _, _, color in app.RAIN_COLOR_STEPS]
        self.assertEqual(
            legend_rgb, server_rgb,
            "iOS legend palette drifted from server RAIN_COLOR_STEPS",
        )


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
