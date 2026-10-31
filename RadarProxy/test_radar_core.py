import os
import sys
import unittest
import gzip
import io
import json
import math
import tempfile
import time
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
        with open(swift_path, encoding="utf-8") as handle:
            source = handle.read()
        block = source.split("static let steps")[1].split("]")[0]
        hexes = re.findall(r'Color\(hex:\s*"#([0-9a-fA-F]{6})"\)', block)
        legend_rgb = [tuple(int(h[i:i + 2], 16) for i in (0, 2, 4)) for h in hexes]
        server_rgb = [color[:3] for _, _, color in app.RAIN_COLOR_STEPS]
        self.assertEqual(
            legend_rgb, server_rgb,
            "iOS legend palette drifted from server RAIN_COLOR_STEPS",
        )


class RadarCoreTests(unittest.TestCase):
    def test_parse_frame_decodes_a_real_odim_h5_rv_member(self) -> None:
        # Regression guard for DWD's late-2025 RV format migration (legacy
        # RADOLAN binary -> ODIM_H5): decodes an actual DWD tar member saved
        # as a fixture, so a future format drift fails loudly here instead
        # of silently freezing the live cache again (see
        # RV_ACCUMULATION_TO_HOURLY_RATE's comment for how this was found).
        fixture_path = os.path.join(os.path.dirname(__file__), "testdata", "sample_rv_member.hd5")
        with open(fixture_path, "rb") as handle:
            raw = handle.read()

        frame = app._parse_frame("composite_rv_20261031_0910_120-hd5", raw)

        self.assertIsNotNone(frame)
        self.assertEqual(frame.time, datetime(2026, 10, 31, 11, 10, tzinfo=timezone.utc))
        self.assertTrue(frame.is_forecast)
        self.assertEqual(frame.rain.shape, (app.GRID_HEIGHT, app.GRID_WIDTH))
        # Known-good values for this exact fixture (computed independently
        # from the file's own gain/offset/nodata attributes) — a wrong
        # scale factor (e.g. missing the accumulation->rate *12, or reusing
        # the legacy /10 RADOLAN scale) would miss this badly.
        self.assertAlmostEqual(float(frame.rain.max()), 10.33, delta=0.1)
        self.assertGreater(int((frame.rain > 0).sum()), 0)

    def test_parse_frame_rejects_an_unparseable_member_name(self) -> None:
        self.assertIsNone(app._parse_frame("not-a-recognized-name", b"irrelevant"))

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

    def test_tile_render_scale_drops_to_one_past_configured_zoom(self) -> None:
        old_cutoff = app.TILE_RENDER_SCALE_MAX_ZOOM
        old_scale = app.TILE_RENDER_SCALE
        try:
            app.TILE_RENDER_SCALE_MAX_ZOOM = 7
            app.TILE_RENDER_SCALE = 2
            self.assertEqual(app._tile_render_scale(0), 2)
            self.assertEqual(app._tile_render_scale(7), 2)
            self.assertEqual(app._tile_render_scale(8), 1)
            self.assertEqual(app._tile_render_scale(14), 1)
        finally:
            app.TILE_RENDER_SCALE_MAX_ZOOM = old_cutoff
            app.TILE_RENDER_SCALE = old_scale

    def test_render_tile_output_size_is_constant_across_the_new_deep_zoom_range(self) -> None:
        # The deep-zoom extension (TILE_MAX_ZOOM now 14) must still produce a
        # normal TILE_SIZE x TILE_SIZE PNG regardless of which supersampling
        # branch `_tile_render_scale` picks for that zoom.
        image = Image.new("RGBA", (app.GRID_WIDTH, app.GRID_HEIGHT), (10, 20, 30, 128))
        west, south, east, north = app.RADAR_BBOX
        lon = (west + east) / 2.0
        lat = (south + north) / 2.0

        for z in (6, 7, 8, app.TILE_MAX_ZOOM):
            x, y = app._lon_lat_to_tile(lon, lat, z)
            data = app._render_tile(image, z, x, y)
            decoded = Image.open(io.BytesIO(data))
            self.assertEqual(decoded.size, (app.TILE_SIZE, app.TILE_SIZE), f"zoom {z}")

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

    def test_region_pack_without_window_args_keeps_legacy_behavior(self) -> None:
        # Direct callers (and these tests) that don't pass window_start/
        # window_end must keep getting every usable frame, unchanged from
        # before the windowing feature existed.
        rain = np.ones((app.GRID_HEIGHT, app.GRID_WIDTH), dtype=np.float32)
        frames = [
            app.RadarFrame(
                frame_id=f"frame-{hour}",
                time=datetime(2026, 7, 5, hour, tzinfo=timezone.utc),
                is_forecast=False,
                image=Image.new("RGBA", (1, 1), (0, 0, 0, 0)),
                rain=rain,
            )
            for hour in (6, 10, 14)
        ]
        cache = app.RadarCache(loaded_at=1.0, frames=frames, tile_cache={})

        packed = app._build_region_pack(cache, 50.0, 9.0, 130.0, 16)
        header_raw, _ = gzip.decompress(packed).split(b"\n", 1)
        header = json.loads(header_raw.decode("utf-8"))

        self.assertEqual([f["id"] for f in header["frames"]], ["frame-6", "frame-10", "frame-14"])

    def test_region_pack_window_filters_frames_outside_range(self) -> None:
        rain = np.ones((app.GRID_HEIGHT, app.GRID_WIDTH), dtype=np.float32)
        frames = [
            app.RadarFrame(
                frame_id=f"frame-{hour}",
                time=datetime(2026, 7, 5, hour, tzinfo=timezone.utc),
                is_forecast=False,
                image=Image.new("RGBA", (1, 1), (0, 0, 0, 0)),
                rain=rain,
            )
            for hour in (6, 10, 14)
        ]
        cache = app.RadarCache(loaded_at=1.0, frames=frames, tile_cache={})

        packed = app._build_region_pack(
            cache,
            50.0,
            9.0,
            130.0,
            16,
            datetime(2026, 7, 5, 9, tzinfo=timezone.utc),
            datetime(2026, 7, 5, 11, tzinfo=timezone.utc),
        )
        header_raw, _ = gzip.decompress(packed).split(b"\n", 1)
        header = json.loads(header_raw.decode("utf-8"))

        self.assertEqual([f["id"] for f in header["frames"]], ["frame-10"])

    def test_region_pack_window_raises_when_nothing_matches(self) -> None:
        rain = np.ones((app.GRID_HEIGHT, app.GRID_WIDTH), dtype=np.float32)
        frame = app.RadarFrame(
            frame_id="frame-6",
            time=datetime(2026, 7, 5, 6, tzinfo=timezone.utc),
            is_forecast=False,
            image=Image.new("RGBA", (1, 1), (0, 0, 0, 0)),
            rain=rain,
        )
        cache = app.RadarCache(loaded_at=1.0, frames=[frame], tile_cache={})

        with self.assertRaises(app.HTTPException) as context:
            app._build_region_pack(
                cache,
                50.0,
                9.0,
                130.0,
                16,
                datetime(2026, 7, 5, 20, tzinfo=timezone.utc),
                datetime(2026, 7, 5, 21, tzinfo=timezone.utc),
            )
        self.assertEqual(context.exception.status_code, 404)

    def test_region_pack_window_spans_observed_radar_and_icon_eu_model_together(self) -> None:
        # The region-pack endpoint is the one seam between live radar and the
        # ICON-EU model forecast: a window reaching two days out must come
        # back with both an observed radar frame and a model frame in the
        # same pack, not force the client to stitch two separate responses.
        rain = np.ones((app.GRID_HEIGHT, app.GRID_WIDTH), dtype=np.float32)
        observed = app.RadarFrame(
            frame_id="DE1200_RV2607051000_000",
            time=datetime(2026, 7, 5, 10, tzinfo=timezone.utc),
            is_forecast=False,
            image=Image.new("RGBA", (1, 1), (0, 0, 0, 0)),
            rain=rain,
        )
        model = app.RadarFrame(
            frame_id="iconraw--20260705T060000Z--036",
            time=datetime(2026, 7, 6, 18, tzinfo=timezone.utc),  # +36h, within a 48h window
            is_forecast=True,
            image=Image.new("RGBA", (1, 1), (0, 0, 0, 0)),
            rain=rain,
        )
        cache = app.RadarCache(loaded_at=1.0, frames=[observed, model], tile_cache={})

        packed = app._build_region_pack(
            cache,
            50.0,
            9.0,
            130.0,
            16,
            datetime(2026, 7, 5, 9, tzinfo=timezone.utc),
            datetime(2026, 7, 7, 10, tzinfo=timezone.utc),
        )
        header_raw, _ = gzip.decompress(packed).split(b"\n", 1)
        header = json.loads(header_raw.decode("utf-8"))

        self.assertEqual([f["id"] for f in header["frames"]], [observed.frame_id, model.frame_id])

    def test_resolve_region_pack_window_all_skips_windowing(self) -> None:
        self.assertEqual(app._resolve_region_pack_window("all", None, None), (None, None))

    def test_resolve_region_pack_window_defaults_around_now(self) -> None:
        before = datetime.now(timezone.utc)
        start, end = app._resolve_region_pack_window("window", None, None)
        after = datetime.now(timezone.utc)

        expected_start_lower = before - app.timedelta(hours=app.REGION_PACK_DEFAULT_PAST_HOURS)
        expected_start_upper = after - app.timedelta(hours=app.REGION_PACK_DEFAULT_PAST_HOURS)
        self.assertTrue(expected_start_lower <= start <= expected_start_upper)

        expected_end_lower = before + app.timedelta(hours=app.REGION_PACK_DEFAULT_FUTURE_HOURS)
        expected_end_upper = after + app.timedelta(hours=app.REGION_PACK_DEFAULT_FUTURE_HOURS)
        self.assertTrue(expected_end_lower <= end <= expected_end_upper)

    def test_resolve_region_pack_window_honors_explicit_bounds(self) -> None:
        start, end = app._resolve_region_pack_window(
            "window", "2026-07-05T09:00:00Z", "2026-07-05T11:00:00Z"
        )
        self.assertEqual(start, datetime(2026, 7, 5, 9, tzinfo=timezone.utc))
        self.assertEqual(end, datetime(2026, 7, 5, 11, tzinfo=timezone.utc))

    def test_resolve_region_pack_window_rejects_inverted_bounds(self) -> None:
        with self.assertRaises(app.HTTPException) as context:
            app._resolve_region_pack_window("window", "2026-07-05T11:00:00Z", "2026-07-05T09:00:00Z")
        self.assertEqual(context.exception.status_code, 400)

    def test_resolve_region_pack_window_rejects_malformed_timestamp(self) -> None:
        with self.assertRaises(app.HTTPException) as context:
            app._resolve_region_pack_window("window", "not-a-date", None)
        self.assertEqual(context.exception.status_code, 400)

    def test_dwd_rv_forecast_frames_keep_distinct_cache_and_pack_keys(self) -> None:
        rain_a = np.ones((app.GRID_HEIGHT, app.GRID_WIDTH), dtype=np.float32)
        rain_b = np.full((app.GRID_HEIGHT, app.GRID_WIDTH), 2.0, dtype=np.float32)
        time_a, offset_a = app._rv_time_from_member_name("composite_rv_20260705_1310_010-hd5")
        time_b, offset_b = app._rv_time_from_member_name("composite_rv_20260705_1310_030-hd5")
        frame_a = app.RadarFrame(
            frame_id="composite_rv_20260705_1310_010-hd5",
            time=time_a,
            is_forecast=offset_a > 0,
            image=Image.new("RGBA", (1, 1), (0, 0, 0, 0)),
            rain=rain_a,
        )
        frame_b = app.RadarFrame(
            frame_id="composite_rv_20260705_1310_030-hd5",
            time=time_b,
            is_forecast=offset_b > 0,
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
            ["composite_rv_20260705_1310_010-hd5", "composite_rv_20260705_1310_030-hd5"],
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


class DeepZoomHotspotWarmTests(unittest.TestCase):
    """Deep zoom (10-14) pre-warming must stay scoped to the single active
    location (set via /warm-location) and a compact radius around it, never
    spread across every saved hotspot — that's what keeps it cheap enough
    for the Beelink's 2 cores."""

    def setUp(self) -> None:
        self.saved_active = app._active_hotspot
        self.saved_dynamic = list(app._dynamic_hotspots)
        self.saved_tile_bytes = app._tile_bytes
        self.saved_warm_stats = app._warm_stats
        self.saved_workers = app.WARM_WORKERS
        app.WARM_WORKERS = 1  # deterministic single-threaded task execution
        app._dynamic_hotspots[:] = []

    def tearDown(self) -> None:
        app._active_hotspot = self.saved_active
        app._dynamic_hotspots[:] = self.saved_dynamic
        app._tile_bytes = self.saved_tile_bytes
        app._warm_stats = self.saved_warm_stats
        app.WARM_WORKERS = self.saved_workers
        app._warming = False

    def _run_warm_with_recorder(self) -> set:
        rendered: set = set()

        def fake_tile_bytes(cache, frame, z, x, y):
            rendered.add((z, x, y))
            return b"", True

        app._tile_bytes = fake_tile_bytes
        frame = app.RadarFrame(
            frame_id="frame-0",
            time=datetime(2026, 7, 5, 10, tzinfo=timezone.utc),
            is_forecast=False,
            image=Image.new("RGBA", (1, 1), (0, 0, 0, 0)),
        )
        cache = app.RadarCache(loaded_at=1.0, frames=[frame], tile_cache={})
        app._warm_tiles_background(cache, cache.loaded_at)
        return rendered

    def test_deep_zoom_tiles_are_only_warmed_for_the_active_location(self) -> None:
        app._active_hotspot = (50.0, 9.0)
        app._dynamic_hotspots[:] = [(50.0, 9.0), (52.0, 13.0)]  # active + another saved location, ~250km apart

        rendered = self._run_warm_with_recorder()

        active_deep_tiles = {
            (z, x, y)
            for z in app.HOTSPOT_DEEP_ZOOMS
            for x, y in app._hotspot_view_tile_paths(z, 50.0, 9.0, app.HOTSPOT_DEEP_HALF_KM)
        }
        other_deep_tiles = {
            (z, x, y)
            for z in app.HOTSPOT_DEEP_ZOOMS
            for x, y in app._hotspot_view_tile_paths(z, 52.0, 13.0, app.HOTSPOT_DEEP_HALF_KM)
        }

        self.assertTrue(rendered & active_deep_tiles, "expected the active location's deep-zoom tiles to be warmed")
        self.assertFalse(
            rendered & (other_deep_tiles - active_deep_tiles),
            "the non-active saved location must not get deep-zoom pre-warming",
        )

    def test_deep_zoom_tiles_are_skipped_when_no_location_is_active(self) -> None:
        app._active_hotspot = None
        app._dynamic_hotspots[:] = [(50.0, 9.0)]

        rendered = self._run_warm_with_recorder()

        self.assertFalse({z for (z, x, y) in rendered if z in app.HOTSPOT_DEEP_ZOOMS})


class WarmLocationEndpointTests(unittest.TestCase):
    """/warm-location is the app's existing "this is now the active
    location" signal (called on every switch/open) — it must record that
    point as the active hotspot, not just add it to the general list."""

    def setUp(self) -> None:
        from fastapi.testclient import TestClient
        import tempfile, pathlib
        self.tmp = tempfile.NamedTemporaryFile(suffix=".json", delete=False)
        app.HOTSPOTS_STATE_PATH = pathlib.Path(self.tmp.name)
        self.saved_active = app._active_hotspot
        self.saved_dynamic = list(app._dynamic_hotspots)
        self.saved_cache = app._cache
        app._active_hotspot = None
        app._dynamic_hotspots[:] = []
        # Fresh, frame-less cache: _ensure_cache() returns it without any
        # network call, and _schedule_tile_warm() no-ops on empty frames —
        # this test is about the active-hotspot bookkeeping, not warming.
        app._cache = app.RadarCache(loaded_at=time.time(), frames=[], tile_cache={})
        self.client = TestClient(app.app)
        self.headers = {"x-radar-token": "test-token"}

    def tearDown(self) -> None:
        app._active_hotspot = self.saved_active
        app._dynamic_hotspots[:] = self.saved_dynamic
        app._cache = self.saved_cache

    def test_warm_location_sets_the_active_hotspot(self) -> None:
        response = self.client.get("/warm-location", params={"lat": 50.1, "lon": 9.1}, headers=self.headers)

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["activeHotspot"], {"lat": 50.1, "lon": 9.1})
        self.assertEqual(app._active_hotspot_snapshot(), {"lat": 50.1, "lon": 9.1})

    def test_warm_location_moves_the_active_point_to_the_front_of_the_saved_list(self) -> None:
        self.client.get("/warm-location", params={"lat": 50.1, "lon": 9.1}, headers=self.headers)
        self.client.get("/warm-location", params={"lat": 52.5, "lon": 13.4}, headers=self.headers)

        self.assertEqual(app._active_hotspot_snapshot(), {"lat": 52.5, "lon": 13.4})
        self.assertEqual(app._dynamic_hotspots[0], (52.5, 13.4))
        self.assertIn((50.1, 9.1), app._dynamic_hotspots)


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


class TileEndpointTests(unittest.TestCase):
    """Guards the tile-coordinate validation added to keep the public
    /tiles endpoint from accepting out-of-range zoom/x/y (bigint zoom would
    otherwise waste CPU on 2**z before anything else looks at the request)."""

    def setUp(self) -> None:
        from fastapi.testclient import TestClient
        self.client = TestClient(app.app)
        self.headers = {"x-radar-token": "test-token"}

    def test_rejects_zoom_above_maximum(self) -> None:
        response = self.client.get("/tiles/frame/999/0/0.png", headers=self.headers)
        self.assertEqual(response.status_code, 422)

    def test_rejects_out_of_range_tile_coordinate(self) -> None:
        # z=2 has a 4x4 tile grid (0..3); x=4 is out of range for that zoom.
        response = self.client.get("/tiles/frame/2/4/0.png", headers=self.headers)
        self.assertEqual(response.status_code, 400)


if __name__ == "__main__":
    unittest.main()
