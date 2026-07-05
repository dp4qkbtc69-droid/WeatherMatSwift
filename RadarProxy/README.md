# WeatherMat DWD Radar Proxy

Small tile proxy for the DWD OpenData radar composite `DE1200_RV_LATEST.tar.bz2`.

The iOS app cannot consume the official DWD `tar.bz2` radar archive directly as a
MapKit tile overlay. This service downloads the DWD archive, renders each radar
frame to a transparent raster, and serves Web-Mercator PNG tiles.

## Run locally

```bash
python3 -m venv .venv
. .venv/bin/activate
pip install -r requirements.txt
uvicorn app:app --host 0.0.0.0 --port 8787
```

Then add this key to `WeatherMat/LocalConfig.plist`:

```xml
<key>dwdRadarTileBaseURL</key>
<string>http://127.0.0.1:8787</string>
```

For a real iPhone build, deploy this service to a small server and use the HTTPS
URL instead of `127.0.0.1`.

## Server Deploy With HTTPS

Recommended target: a small VPS with Docker and Docker Compose. Point a DNS
record such as `radar.example.com` to the server first. Ports `80` and `443`
must be reachable from the internet so Caddy can request and renew the TLS
certificate.

```bash
cp .env.example .env
```

Edit `.env`:

```dotenv
RADAR_DOMAIN=radar.example.com
DWD_RADAR_PAST_HOURS=24
DWD_RADAR_PAST_STEP_MINUTES=15
DWD_RADAR_CACHE_SECONDS=240
```

Start:

```bash
docker compose up -d --build
```

Check:

```bash
curl https://radar.example.com/health
curl https://radar.example.com/timeline.json
```

Then set the app config:

```xml
<key>dwdRadarTileBaseURL</key>
<string>https://radar.example.com</string>
```

For updates:

```bash
docker compose pull
docker compose up -d --build
```

Logs:

```bash
docker compose logs -f radar-proxy
docker compose logs -f caddy
```

## Endpoints

- `GET /health`, `GET /metrics`
- `GET /timeline.json` — frame list (native DWD-RV nowcast + ICON-EU raw
  forecast), each frame's `source`, `precipitationType`, and (for model
  frames) `referenceTime` of the model run.
- `GET /tiles/{frame_id}/{z}/{x}/{y}.png` — server-rendered tiles (tile
  pipeline; kept as a fallback outside the packed region / at deep zoom).
- `GET /region-pack?lat=&lon=&km=&frames=all` — compact gzip package of raw
  intensity rasters (rain + optional snow, quantized uint8) for a local
  region, plus the colour palette/threshold parameters in the header. The
  iOS client renders this itself instead of loading tiles per frame — this is
  what makes radar playback fast (and mostly network-free) on mobile data.
- `POST /warm-location` / `POST /warm-locations` — register one or many user
  locations so their detail-zoom tiles and region are pre-warmed.

The proxy refreshes the DWD archive every `DWD_RADAR_REFRESH_INTERVAL_SECONDS`
(default 300s / 5 min).

### Rendering & optics

- `DWD_RADAR_SMOOTH_PALETTE` (default `true`) — continuous colour ramp
  interpolated over `RAIN_COLOR_STEPS`/`SNOW_COLOR_STEPS` instead of hard
  bands. Palette is a conventional rainbow (cyan → green → yellow → orange →
  red → magenta) so in-between hues stay meaningful.
- `DWD_RADAR_MIN_INTENSITY` (default `0.3` mm/h) — hides precip below this
  rate (drizzle/virga/clutter) to declutter the view.
- `DWD_RADAR_FEATHER_RADIUS` (default `0.8`) — softens precip-area edges
  (alpha-channel blur).
- `DWD_RADAR_HANDOFF_MINUTES` (default `60`) — linearly blends the first
  ICON-EU model frames against the last DWD-RV nowcast field over this many
  minutes, so the nowcast→model handoff isn't an abrupt jump. `0` disables it.
- `DWD_RADAR_REGION_GRID_SIZE` (default `384`), `DWD_RADAR_REGION_QUANT_SCALE`
  (default `5.0`) — region-pack raster resolution and intensity quantization.

### Pre-warming

- `DWD_RADAR_WARM_TILES`/`DWD_RADAR_WARM_WORKERS` (default `1`, keep at 1 on a
  2-core box — parallel warming starves live playback requests),
  `DWD_RADAR_WARM_FRAME_LIMIT`/`_ZOOMS`/`_DETAIL_*` — background tile warming.
- `DWD_RADAR_HOTSPOT_WARM`, `DWD_RADAR_HOTSPOT_DETAIL_ZOOMS`/`_HALF_KM` — warm
  the app's local open-view detail zooms around each hotspot (static
  `DWD_RADAR_HOTSPOT_LAT`/`LON` plus dynamic ones from `/warm-location(s)`,
  capped at `DWD_RADAR_DYNAMIC_HOTSPOTS_MAX`, default 16, persisted to
  `HOTSPOTS_STATE_PATH` so they survive a restart).

### Other

- `DWD_RADAR_PAST_HOURS`, default `24`
- `DWD_RADAR_PAST_STEP_MINUTES`, default `15`
- `DWD_RADAR_CACHE_SECONDS`, default `240`
- `RADAR_PROXY_TOKEN`, optional locally but strongly recommended for every
  publicly reachable deployment
- `RADAR_DISK_CACHE_DIR`, optional path for persistent rendered tile cache

## Server Choice

The proxy can technically run anywhere with Python 3.12 and enough memory, but
the clean production setup is a VPS/container host with the bundled Caddy
setup for HTTPS (see "Server Deploy With HTTPS" above).

## DWD Warning Push (APNs)

The proxy polls BrightSky/DWD alerts for all registered device locations
(every `WARNING_POLL_SECONDS`, default 300) and delivers new warnings at or
above `APNS_MIN_SEVERITY` (default `Moderate`) via APNs. The app registers its
device token and saved locations automatically at `POST /push/register`.

One-time setup:

1. Create an APNs auth key at developer.apple.com under
   `Certificates, Identifiers & Profiles > Keys` (enable "Apple Push
   Notifications service"). Download the `AuthKey_XXXXXXXXXX.p8` file —
   it can only be downloaded once.
2. Copy it to the server as `/opt/weathermat-radar/apns/AuthKey.p8`.
3. Add to `.env`:

```
APNS_TEAM_ID=5P532N3MK4
APNS_KEY_ID=XXXXXXXXXX      # the 10-char id from the key name
APNS_USE_SANDBOX=true       # true for Xcode/debug builds, false for TestFlight/App Store
```

4. `docker compose up -d --build`

`/health` metrics show `pushRegistrations`, `pushSent`, `pushErrors`.
Without a configured key the poller stays off and the app falls back to
local warning notifications.
