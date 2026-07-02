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

- `GET /health`
- `GET /timeline.json`
- `GET /tiles/{frame_id}/{z}/{x}/{y}.png`

The proxy refreshes the DWD archive every four minutes.

Optional environment variables:

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
