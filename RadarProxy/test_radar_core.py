import os
import sys
import unittest
import gzip
import json
import math
import tempfile
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

    def test_region_sampler_uses_linear_radar_bbox_mapping(self) -> None:
        source = np.arange(100, dtype=np.float32).reshape((10, 10))
        west, south, east, north = app.RADAR_BBOX
        lon = (west + east) / 2.0
        lat = (south + north) / 2.0
        mercator = app._region_mercator_rect(lat, lon, 20.0)

        sampled = app._sample_region_grid(source, mercator, 8)

        self.assertEqual(sampled.shape, (8, 8))
        self.assertGreater(sampled.mean(), source[3:7, 3:7].min())
        self.assertLess(sampled.mean(), source[3:7, 3:7].max())

    def test_region_mercator_rect_interprets_km_as_ground_distance(self) -> None:
        lat = 50.0
        lon = 9.0
        rect = app._region_mercator_rect(lat, lon, 130.0)
        west, _ = app._mercator_to_lon_lat(rect[0], rect[1])
        east, _ = app._mercator_to_lon_lat(rect[2], rect[3])
        ground_width_m = (rect[2] - rect[0]) * math.cos(math.radians(lat))

        self.assertAlmostEqual(ground_width_m / 1000.0, 130.0, delta=0.1)
        self.assertGreater(east - west, 1.7)

    def test_region_pack_header_offsets_roundtrip(self) -> None:
        time = datetime(2026, 7, 5, 10, tzinfo=timezone.utc)
        rain = np.ones((app.GRID_HEIGHT, app.GRID_WIDTH), dtype=np.float32)
        snow = np.full((app.GRID_HEIGHT, app.GRID_WIDTH), 0.5, dtype=np.float32)
        frame = app.RadarFrame(
            frame_id="DE1200_RV2607051000_000",
            time=time,
            is_forecast=False,
            image=Image.new("RGBA", (1, 1), (0, 0, 0, 0)),
            rain=rain,
            snow=snow,
            reference_time=time,
            precipitation_type="mixed",
        )
        cache = app.RadarCache(loaded_at=1.0, frames=[frame], tile_cache={})

        packed = app._build_region_pack(cache, 50.0, 9.0, 130.0, 16)
        decoded = gzip.decompress(packed)
        header_raw, payload = decoded.split(b"\n", 1)
        header = json.loads(header_raw.decode("utf-8"))

        self.assertEqual(header["grid"], {"w": 16, "h": 16})
        self.assertEqual(header["frames"][0]["offsetBytes"], 0)
        self.assertEqual(header["frames"][0]["snowOffsetBytes"], 256)
        self.assertEqual(header["frames"][0]["referenceTime"], "2026-07-05T10:00:00+00:00")
        self.assertEqual(len(payload), 512)
        self.assertEqual(payload[0], 5)
        self.assertEqual(payload[256], 2)

    def test_dwd_rv_forecast_frames_keep_distinct_cache_and_pack_keys(self) -> None:
        rain_a = np.ones((app.GRID_HEIGHT, app.GRID_WIDTH), dtype=np.float32)
        rain_b = np.full((app.GRID_HEIGHT, app.GRID_WIDTH), 2.0, dtype=np.float32)
        time_a, forecast_a = app._time_from_name("DE1200_RV2607051310_010")
        time_b, forecast_b = app._time_from_name("DE1200_RV2607051310_030")
        frame_a = app.RadarFrame(
            frame_id="DE1200_RV2607051310_010",
            time=time_a,
            is_forecast=forecast_a,
            image=Image.new("RGBA", (1, 1), (0, 0, 0, 0)),
            rain=rain_a,
        )
        frame_b = app.RadarFrame(
            frame_id="DE1200_RV2607051310_030",
            time=time_b,
            is_forecast=forecast_b,
            image=Image.new("RGBA", (1, 1), (0, 0, 0, 0)),
            rain=rain_b,
        )

        self.assertNotEqual(frame_a.frame_id, frame_b.frame_id)
        self.assertNotEqual(frame_a.time, frame_b.time)
        self.assertNotEqual((frame_a.frame_id, 8, 134, 88), (frame_b.frame_id, 8, 134, 88))

        with tempfile.TemporaryDirectory() as tmp:
            old_dir = app.DISK_CACHE_DIR
            try:
                app.DISK_CACHE_DIR = app.Path(tmp)
                self.assertNotEqual(
                    app._disk_tile_path(frame_a.frame_id, 8, 134, 88),
                    app._disk_tile_path(frame_b.frame_id, 8, 134, 88),
                )
            finally:
                app.DISK_CACHE_DIR = old_dir

        cache = app.RadarCache(loaded_at=1.0, frames=[frame_a, frame_b], tile_cache={})
        packed = app._build_region_pack(cache, 49.0, 8.4, 80.0, 16)
        header_raw, _ = gzip.decompress(packed).split(b"\n", 1)
        header = json.loads(header_raw.decode("utf-8"))
        self.assertEqual(
            [frame["id"] for frame in header["frames"]],
            ["DE1200_RV2607051310_010", "DE1200_RV2607051310_030"],
        )

    def test_icon_handoff_blends_only_inside_window(self) -> None:
        old_minutes = app.RADAR_HANDOFF_MINUTES
        try:
            app.RADAR_HANDOFF_MINUTES = 60
            after = datetime(2026, 7, 5, 14, tzinfo=timezone.utc)
            nowcast = app.RadarFrame(
                frame_id="DE1200_RV2607051310_120",
                time=after,
                is_forecast=True,
                image=Image.new("RGBA", (1, 1), (0, 0, 0, 0)),
                rain=np.full((2, 2), 2.0, dtype=np.float32),
            )
            model_early = app.RadarFrame(
                frame_id="iconraw--20260705T090000Z--006",
                time=after + app.timedelta(minutes=15),
                is_forecast=True,
                image=Image.new("RGBA", (1, 1), (0, 0, 0, 0)),
                rain=np.full((2, 2), 10.0, dtype=np.float32),
                snow=np.zeros((2, 2), dtype=np.float32),
                reference_time=after,
            )
            model_late = app.RadarFrame(
                frame_id="iconraw--20260705T090000Z--007",
                time=after + app.timedelta(minutes=60),
                is_forecast=True,
                image=Image.new("RGBA", (1, 1), (0, 0, 0, 0)),
                rain=np.full((2, 2), 10.0, dtype=np.float32),
                snow=np.zeros((2, 2), dtype=np.float32),
                reference_time=after,
            )

            blended = app._apply_icon_handoff([model_early, model_late], after, nowcast)

            self.assertAlmostEqual(float(blended[0].rain[0, 0]), 4.0, places=4)
            self.assertAlmostEqual(float(blended[1].rain[0, 0]), 10.0, places=4)
        finally:
            app.RADAR_HANDOFF_MINUTES = old_minutes

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
