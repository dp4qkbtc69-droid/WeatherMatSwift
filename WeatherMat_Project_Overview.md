# WeatherMat – Projektübersicht (aktueller Stand)

Zweck dieses Dokuments: vollständiger Kontext für eine KI-Analyse des
gesamten Projekts. Ersetzt die vorherige Fassung dieses Dokuments sowie das
ältere `WeatherMat_Radar_Overview.md` (dessen Probleme inzwischen vollständig
behoben sind, siehe Abschnitt 7). Siehe auch `WeatherMat_Audit.md` für ein
allgemeines Code-Audit (Security/Architektur, Stand vor den hier
beschriebenen Arbeiten).

## 1. Projekt im Überblick

**WeatherMat** ist eine SwiftUI-iOS-App mit watchOS-Begleit-App, Home-Screen-
Widgets, Live Activities, Siri/Shortcuts-Integration und einem selbst
betriebenen Python-Backend für das Regenradar.

Repo-Layout:
- `WeatherMat/` – iOS-App (Swift 6, SwiftUI, `@Observable`, strukturierte
  Nebenläufigkeit).
- `WeatherMatWatch/` – watchOS-Companion-App (eigenes WeatherKit-Fetching,
  Complication).
- `WeatherMatWidgets/` – Home-Screen-Widgets + Live Activities (Regenradar-
  Countdown, Unwetterwarnung).
- `WeatherMatShared/` – von App und Widgets gemeinsam genutzte
  `ActivityAttributes`-Typen für Live Activities.
- `WeatherMat/AppIntents/` – Siri/Shortcuts-Integration.
- `WeatherMatTests/` – Unit-Tests (Swift Testing Framework), 40 Tests in
  6 Suiten, alle grün.
- `RadarProxy/` – eigenständiger FastAPI/Python-Dienst (`app.py`, ~2440
  Zeilen) für DWD-Radardaten. **Läuft als genau eine Instanz**: ein Home-
  Assistant-Add-on auf einem lokalen Mini-PC (siehe Abschnitt 6.4). Ein
  früher zusätzlich betriebener netcup-VPS ist seit dieser Session bestätigt
  stillgelegt/nicht mehr referenziert.

Git-Status: Hauptbranch `main`, Arbeitsbaum **sauber** – alles ist
committet (aktuellste Commits: `9bc3041`, `b9c3187`) und nach `origin/main`
gepusht.

## 2. Gesamtarchitektur

MVVM-artig. `WeatherViewModel` (`WeatherMat/ViewModels/WeatherViewModel.swift`,
~400 Zeilen) ist nicht mehr das frühere "God Object" (vormals ~570 Zeilen,
siehe `WeatherMat_Audit.md`), sondern wurde aufgeteilt:

- **`LocationStore`** (`WeatherMat/ViewModels/LocationStore.swift`, neu,
  `@MainActor @Observable`) – Standortliste, Standortwechsel, GPS-Erfassung
  (inkl. `GPSQuickCheck`/`GPSAcquisitionResult`-Enums, die die ursprüngliche
  Verzweigungslogik von `useGPSLocation` exakt nachbilden).
- **`RadarPrewarmController`** (`WeatherMat/Services/RadarPrewarmController.swift`,
  neu, statischer Namespace wie `RainRadarService` vormals) – Radar-
  Prewarming/Hintergrund-Trigger, 1:1 aus dem ViewModel extrahiert.
- **`WeatherViewModel`** selbst dient jetzt als dünne Orchestrierungsschicht
  für die Haupt-Views, delegiert Standort-/GPS-Logik an `LocationStore`.

Navigation (`ContentView.swift`): `horizontalSizeClass == .regular` (iPad)
→ `NavigationSplitView` mit permanenter Sidebar (`LocationsView`); sonst
(iPhone) → `WeatherView` + `LocationsView` als Sheet.

### Service-Schicht: von Singleton-Enums zu DI-fähigen Klassen

`RainRadarService`, `RegionPackService`, `EnsembleService` sind nicht mehr
statische `enum`-Namespaces, sondern `final class`es mit:
- einem Protokoll (`RainRadarServiceProtocol`, `RegionPackServiceProtocol`,
  `EnsembleServiceProtocol`) für Mockbarkeit in Tests,
- `static let shared` als Produktions-Default,
- Initializer-Injection in Consumer (`RadarV2Store`, `RegionPackController`,
  `WeatherViewModel`) mit `= .shared` als Default-Argument, sodass bestehende
  Call-Sites unverändert bleiben.

`OpenMeteoService` nutzt weiterhin sein bestehendes `WeatherProviding`-
Protokoll; `EnsembleService.init(providers:)` macht dessen Provider-Liste
injizierbar, ohne ein zusätzliches Protokoll einzuführen.

Weitere Services (größtenteils weiterhin statische `enum`/Singleton-APIs,
nicht Teil der DI-Arbeit):
- **Wetterdaten:** `OpenMeteoService`, `WeatherKitService`, `BrightSkyService`,
  `AirQualityService`, `WaterTemperatureService`, `EnsembleService`
  (gewichtet/kombiniert alle Quellen, inkl. Modell-Disagreement-Anzeige als
  Temperaturspanne an unsicheren Tagen).
- **Lokale Station:** `NetatmoService` (OAuth2, Keychain-Token).
- **Standort/Geo:** `LocationService`, `GeocodingService`.
- **Radar:** `RainRadarService`, `RegionPackService` (Details: Abschnitt 4).
- **Persistenz:** `WeatherCacheStore` (siehe unten), `ForecastCalibrationStore`.
- **Sonstiges:** `Where2GoService`, `PushRegistrationService` (APNs-
  Registrierung beim Radar-Proxy), `NotificationService`,
  `WatchConnectivityService`, `LiveActivityController` (startet/aktualisiert/
  beendet die zwei Live Activities: Radar-Countdown, Unwetterwarnung).

### `WeatherCacheStore`: Thread-Sicherheit

Wird sowohl von `WeatherViewModel` (Hauptapp, MainActor) als auch
asynchron im Hintergrund von App-Intents (Siri/Shortcuts, eigener Prozess-
Kontext) genutzt. Jetzt:
- `NSLock`-geschützter Zugriff für `save`/`load`/`remove`/
  `loadSavedLocations`; `load()` hält den Lock über Read+Decode+bedingtem
  Remove (inline, nicht rekursiv, da `NSLock` nicht reentrant ist – TOCTOU-
  und Deadlock-sicher designt).
- Robuste Fehlerbehandlung: beschädigte Pro-Standort-Cache-Einträge heilen
  sich selbst (werden entfernt); beschädigte `loadSavedLocations`-Daten
  werden geloggt, aber **nicht** gelöscht (echte Nutzerdaten, kein Cache).

`WeatherMat/AppIntents/` (App Shortcuts/Siri): `FindGoodWeatherIntent`,
`RefreshWeatherIntent`, `SavedLocationEntity`, `WeatherMatShortcuts` – laufen
außerhalb des Lebenszyklus des ViewModels, lesen/schreiben über den jetzt
thread-sicheren `WeatherCacheStore`.

## 3. Wetter-Datenfluss (nicht Radar)

```
OpenMeteo / WeatherKit / BrightSky / AirQuality / WaterTemperature / Netatmo
        │
        ▼
EnsembleService  (gewichtete Kombination je nach Horizont/Modellgüte,
                  Temperaturspanne bei geringer Modell-Übereinstimmung)
        │
        ▼
WeatherViewModel  (dünn, delegiert an LocationStore + RadarPrewarmController)
        │
        ▼
WeatherView  (Hero, Hourly, Daily, Stats, RainBanner, Where2Go,
              WaterTemperatureView, TopBar)
```

Dieser Datenfluss selbst war nicht Gegenstand der jüngsten Session-Arbeit
(Fokus lag auf Radar-Architektur + Radar-Backend-Betrieb); die
Service-Schicht-DI und `WeatherCacheStore`-Härtung betreffen ihn aber
mittelbar.

## 4. Radar: Client-Architektur

### 4.1 Ende-zu-Ende-Datenfluss

```
DWD Open Data (Radar-Composite ODIM_H5 + ICON-EU GRIB2/WMS)
        │
        ▼
RadarProxy (Python/FastAPI, app.py) – siehe Abschnitt 6
        │  HTTP (timeline.json / tiles/*.png / region-pack / warm-location)
        ▼
RainRadarService (iOS)   → Timeline laden, 30-Min-Cache, lokal→extern-
                            Fallback-Auflösung (resolveDwdRadarBaseURL)
RegionPackService (iOS)  → Region-Pack laden + dekodieren, inkl. Zeitfenster
        │
        ▼
RadarV2Store (@Observable)  → Timeline-/Playback-Zustand, Frame-Auswahl,
                               Render-Fenster-Berechnung, 120h-Sichtfenster
        │
        ▼
RegionPackController (@Observable)  → Laden + inkrementelles Rendern,
                                       vollständig ereignisgesteuert
        │
        ▼
RainRadarScreen (View)  → orchestriert Controller/Store, Chrome-Logik
        │
        ├─► RadarRegionImageRenderer  → Accelerate/vImage-Pipeline
        │
        └─► RadarV2MapView (MKMapView)  → Region-Overlay oder Tile-Fallback,
                                           dynamisches maximumZ bis 14,
                                           debounced Pan/Zoom
        │
        └─► RadarTimelineControl  → lokal entkoppelter, throttled Scrubber,
                                      Radar/Nowcast/Modell optisch
                                      unterschieden (4.5)
```

### 4.2 Ereignisgesteuerte Lade-/Render-Architektur

Die frühere permanente 220ms-Polling-Schleife in `RainRadarView.swift` ist
vollständig ersetzt durch `RegionPackController.ensureRendered(...)`
(ein begrenzter Durchlauf pro Aufruf statt Polling), `onChange`-Trigger für
Scrubben/Playback/Pack-Fertigstellung, und ein 300ms-Debounce für
Kartenbewegungen. `onDisappear` bricht alle Tasks ab – nichts läuft weiter,
wenn der Radar-Screen nicht sichtbar ist.

### 4.3 Zeitfenster-begrenztes Laden statt "alles"

`/region-pack` akzeptiert `start_time`/`end_time` (ISO8601); der Client
leitet das Fenster aus `store.regionRenderWindow(radius:)` ab (tatsächlich
sichtbares Fenster) statt pauschal die komplette Timeline anzufordern.
`frames=all` bleibt als Debug-Opt-out erhalten.

### 4.4 Pixel-Rendering: Accelerate/vImage

`RadarRegionOverlay.swift`: 256-Einträge-Lookup-Tabelle via
`vImageTableLookUp_Planar8`, Feathering via `vImageBoxConvolve_Planar8`,
Zusammensetzen via `vImageConvert_Planar8toARGB8888`. Läuft in
`Task.detached(priority: .utility)`, nie auf dem MainActor. Pixel-genau
gegen die alte Implementierung verifiziert (bit-identisch ohne Feathering).

### 4.5 Zwei-Tage-Vorhersage: ICON-EU im Scrubber, optisch unterschieden

`RadarV2Store.visibleFrames` behält 24h Historie + bis zu 120h Vorhersage.
`RadarTimelineControl.swift` klassifiziert jeden Frame per neuer
`RadarFrameCategory` (`observed` / `nowcast` / `model`, aus `isForecast` +
`sourceKind`) und zeigt:
- bis zu zwei Handoff-Marker ("Nowcast" bernsteinfarben, "Modell" cyan) an
  den jeweiligen Kategoriewechseln, statt nur einer generischen
  "Vorhersage"-Markierung,
- Ticks im Modell-Bereich durchgehend cyan eingefärbt,
- das Datenquellen-Label farblich synchron zu den Markern.

### 4.6 Tiefes Zoomen (bis 14) + kompaktes Vorwärmen

- Server: `TILE_MAX_ZOOM` 13→14, zoomabhängiges `TILE_RENDER_SCALE`
  (Supersampling nur bis Zoom 7, danach Faktor 1 – native DE1200-Zellen
  sind ~1,2 km, ein 512px-Tile erreicht native Auflösung bereits um Zoom 6).
- Client: `RadarV2TileOverlay.maximumZ` folgt dynamisch dem vom Server
  gemeldeten `tileMaxZoom` (kein hartes Client-Limit).
- **Deep-Zoom-Vorwärmen (10–14) ist auf den einen aktiven Standort
  begrenzt** (`_active_hotspot`, gesetzt über `/warm-location` – genau der
  Call, den die App ohnehin bei jedem Standortwechsel macht), mit engem
  Radius (`HOTSPOT_DEEP_HALF_KM`, 8 km) und kurzer Frame-Zahl
  (`HOTSPOT_DEEP_FRAME_LIMIT`, 24) – nicht für alle gespeicherten Orte,
  da die Kachelzahl pro Zoomstufe etwa vervierfacht und der Mini-PC nur
  2 Kerne hat. Andere Orte/freies Pannen bleiben beim bestehenden
  On-Demand-Rendering.

### 4.7 Scrubber: lokal entkoppelt + throttled

`RadarTimelineControl.swift`: lokaler `liveDragIndex` für sofortiges
visuelles Feedback beim Ziehen, externes `selectedIndex`-Binding nur alle
80ms committet. Tick-Label-Berechnung einmalig in `init` vorberechnet statt
pro Body-Auswertung.

## 5. Watch-App, Widgets, Live Activities, App Intents

- **`WeatherMatWatch/`** – eigenständige watchOS-App.
- **`WeatherMatWidgets/`** + **`WeatherMatShared/`** – zwei Live Activities
  (Regenradar-Countdown, Unwetterwarnung), verwaltet von
  `LiveActivityController`.
- **`WeatherMat/AppIntents/`** – Siri/Shortcuts-Integration
  (`FindGoodWeatherIntent`, `RefreshWeatherIntent`, `SavedLocationEntity`,
  `WeatherMatShortcuts`).

Diese Bereiche sind unabhängig vom Radar-Feature und waren nicht Gegenstand
der jüngsten Backend-Arbeit.

## 6. Backend (`RadarProxy/app.py`) – Gesamtbild

### 6.1 Architektur

FastAPI/Uvicorn, numpy+PIL für Bildverarbeitung, `h5py` für die
Radar-Rohdaten-Dekodierung (neu, siehe 6.2), `ThreadPoolExecutor`/Threads
für Warm-Loops. Mehrstufiges Caching: In-Memory-Tile-Cache, Disk-Cache,
Region-Pack-Cache. Hintergrund-"Warm"-Mechanismus rendert proaktiv Kacheln
für Hotspots & registrierte Nutzer-Standorte. APNs-Push für
Unwetterwarnungen.

### 6.2 Kritischer Fix: DWD hat das Radar-Rohformat umgestellt

**Das war die eigentliche Ursache für "Radar läuft langsam/zeigt nichts
Aktuelles/keine Vorhersage" in dieser Session, nicht Performance.** DWD hat
Ende 2025 das RV-Komposit-Produkt vom Legacy-RADOLAN-Binärformat
(`DE1200_RV_LATEST.tar.bz2`) auf ODIM_H5 umgestellt
(`composite_rv_LATEST.tar`, unkomprimiertes Tar aus einzelnen HDF5-Dateien,
z. B. `composite_rv_20261031_0910_000-hd5`). Die alte feste URL/Parser-
Logik bekam daraufhin bei **jedem** Refresh einen 404 – der Proxy servierte
daraufhin 9 Tage lang stillschweigend denselben veralteten Cache, statt
sichtbar zu fehlern (`_ensure_cache()` liefert eine veraltete-aber-
vorhandene Cache-Instanz sofort aus, während im Hintergrund erfolglos neu
versucht wird).

Fix: `_parse_frame`/`_rv_time_from_member_name`/
`_radar_intensity_from_odim_grid` lesen jetzt HDF5 (`gain`/`offset`/
`nodata` aus den Datei-eigenen Attributen, nicht hartkodiert), multiplizieren
die 5-Minuten-Akkumulation (ODIM-Quantity `ACRR`) mit 12
(`RV_ACCUMULATION_TO_HOURLY_RATE`) für die vom Rest des Moduls erwartete
mm/h-Rate. Abgesichert durch eine committete echte DWD-Beispieldatei
(`RadarProxy/testdata/sample_rv_member.hd5`) plus Regressionstest
(`test_parse_frame_decodes_a_real_odim_h5_rv_member`), damit ein künftiger
Formatwechsel laut in einem Test auffällt statt den Cache erneut
stillschweigend einzufrieren.

**Diagnose-Hinweis für künftige "Radar wirkt kaputt"-Reports:** zuerst
`/metrics`'s `loadedAt`/`lastRefreshError` prüfen – ein alter `loadedAt`
bei leerem `lastRefreshError` bedeutet meist einen seit Langem
fehlschlagenden Hintergrund-Refresh, nicht ein Performance-Problem. Ein
sichtbares Symptom im Client: Kacheln mit eingebranntem Text "Zoom Level
Not Supported" sind RainViewers eigene Platzhalter-Kachel – ein Zeichen,
dass `RainRadarService.fetchTimeline()` auf den RainViewer-Fallback
zurückgefallen ist, weil der DWD-Proxy-Abruf fehlgeschlagen ist (z. B. 503
durch nie erfolgreich gebauten Cache).

### 6.3 Deep-Zoom-Vorwärmen & aktiver Standort (neu)

Siehe Abschnitt 4.6 für die Client-Perspektive. Backend-seitig: `/warm-
location` setzt zusätzlich zur bestehenden `_dynamic_hotspots`-Liste einen
separaten, rein speicherresidenten `_active_hotspot` (bewusst nicht
persistiert – ein Live-Signal, das die App binnen 15 Min. nach jedem
Neustart ohnehin erneut sendet). `_warm_tiles_background` nutzt ihn für
einen zusätzlichen, engen Deep-Zoom-Warm-Block.

### 6.4 Deployment-Topologie (wichtig – in dieser Session korrigiert)

**Es gibt nur noch eine aktive Backend-Instanz: ein Home-Assistant-Add-on
auf einem lokalen Mini-PC** (`local_weathermat_radar`, lokal
`http://192.168.178.34:8787`, extern via Cloudflare-Tunnel
`https://radar.praxis-hartlep.de`). `LocalConfig.plist`s
`dwdRadarTileBaseURL`/`dwdRadarTileExternalBaseURL` referenzieren
ausschließlich diese Instanz. Ein früher parallel betriebener netcup-VPS
(`radar.hartlep.de`) wird vom Client nicht mehr referenziert und ist nicht
mehr Teil der Infrastruktur, obwohl der Server technisch noch erreichbar
sein kann – **für Radar-Fixes nicht mehr relevant**.

Deploy-Prozedur für den Mini-PC: `scp app.py requirements.txt` nach
`/local_apps/weathermat-radar/` auf den Host, dann über SSH (Home
Assistant "Terminal & SSH"-Add-on, Port 22222) `ha apps rebuild
local_weathermat_radar`. Verifikation über die externe Cloudflare-URL, da
Port 8787 vom SSH-Add-on-Container aus nicht direkt erreichbar ist.
`ha apps logs local_weathermat_radar` zeigt Refresh-/Decode-Fehler.

**Deployment-Lektion dieser Session:** Code-Änderungen in diesem Repo
werden durch `git push` **nicht** automatisch live geschaltet – weder für
den Mini-PC noch für (das inzwischen irrelevante) netcup. Ein ganzer
vorheriger Arbeits-Zyklus (Zoom-Erhöhung, Deep-Zoom-Warming, Region-Pack-
Windowing) war über mehrere Sessions hinweg lokal/in git vorhanden, aber nie
deployt worden, bis dies in dieser Session nachgeholt wurde. Nach jeder
`app.py`-Änderung: tatsächlich auf den Mini-PC deployen und per
`/metrics`/`/timeline.json` über die externe URL verifizieren, nicht nur
lokal/im Git-Log davon ausgehen.

### 6.5 Tests

`test_radar_core.py` – **38 Tests**, alle grün. Lokal ausführbar via
`python3 -m venv .venv && .venv/bin/pip install fastapi numpy pillow
pydantic httpx h5py && .venv/bin/python -m unittest test_radar_core -v`
(`eccodes` wird nur für den optionalen ICON-EU-GRIB2-Pfad lazy importiert
und ist für die Tests selbst nicht zwingend nötig, `h5py` dagegen schon,
da der neue RV-HDF5-Decoder direkt getestet wird).

## 7. Historie: Was in den letzten Sessions optimiert/behoben wurde

1. **Pixel-Rendering** → Accelerate/vImage (4.4).
2. **Polling-Schleife entfernt** → ereignisgesteuert (4.2).
3. **Netzwerk-Overfetching** → Zeitfenster + Pan/Zoom-Debounce (4.3).
4. **Scrubber-Performance** → lokal entkoppelt + throttled (4.7).
5. **God-Object-Refactor**: `WeatherViewModel` → `LocationStore` +
   `RadarPrewarmController` (Abschnitt 2).
6. **Service-Schicht-DI**: Singleton-Enums → protokollbasierte,
   mockbare Klassen (Abschnitt 2).
7. **`WeatherCacheStore`-Härtung**: Thread-Sicherheit + Recovery bei
   defekten Caches (Abschnitt 2).
8. **Tiefes Zoomen (bis 14) + kompaktes Deep-Zoom-Warming** (4.6, 6.3).
9. **ICON-EU-Zwei-Tage-Vorhersage im Scrubber**, optisch unterschieden
   (4.5).
10. **Kritischer Produktionsfix**: DWD-ODIM_H5-Formatumstellung erkannt und
    behoben, auf die tatsächlich genutzte Mini-PC-Instanz deployt (6.2,
    6.4).

## 8. Tests – Gesamtstand

- **Swift:** `WeatherMatTests` – 40 Tests in 6 Suiten, alle grün.
- **Python:** `RadarProxy/test_radar_core.py` – 38 Tests, alle grün.
- Build verifiziert via `xcodebuild -scheme WeatherMat -destination
  'platform=iOS Simulator,name=iPhone 17e'` (Debug, build + test).
- Backend-Fix zusätzlich End-to-End gegen die echte DWD-Quelle UND den
  echten Mini-PC-Proxy live verifiziert (nicht nur unit-getestet).

## 9. Aktueller Repo-Status

Arbeitsbaum sauber, alles committet und gepusht. Relevante jüngste Commits:

```
9bc3041 Fix RV radar ingestion for DWD's ODIM_H5 format migration
b9c3187 Radar-Performance-Überholung, ICON-EU-2-Tage-Vorhersage, Live Activities & App Intents
80a5e6a Add sea temperature + tide feature, fix WMOCode test build break
```

## 10. Relevante Dateien für eine Weiterarbeit/KI-Analyse

Radar-Client: `RadarMapView.swift`, `RadarRegionOverlay.swift`,
`RainRadarView.swift`, `RadarV2Store.swift`, `RegionPackController.swift`,
`RadarTimelineControl.swift`, `RegionPackService.swift`,
`RainRadarService.swift`.
Radar-Backend: `RadarProxy/app.py` (insb. `_parse_frame`,
`_radar_intensity_from_odim_grid`, `_warm_tiles_background` für Deep-Zoom-
Warming).
Allgemeine Architektur: `WeatherViewModel.swift`, `LocationStore.swift`,
`RadarPrewarmController.swift`, `ContentView.swift`, `WeatherView.swift`.
Bestehende Dokumente: `WeatherMat_Audit.md` (allgemeines Code-Audit, Stand
vor dieser Arbeit), `WeatherMat_Radar_Overview.md` (historisch, überholt).
