# WeatherMat – Projektübersicht (aktueller Stand)

Zweck dieses Dokuments: vollständiger Kontext für eine KI-Analyse des
gesamten Projekts. Ersetzt/erweitert `WeatherMat_Radar_Overview.md` (dessen
dort beschriebene Radar-Performance-Probleme in dieser Session behoben
wurden, siehe Abschnitt 7). Siehe auch `WeatherMat_Audit.md` für ein
allgemeines Code-Audit (Security/Architektur).

## 1. Projekt im Überblick

**WeatherMat** ist eine SwiftUI-iOS-App mit watchOS-Begleit-App, Home-Screen-
Widgets, Live Activities und einem selbst betriebenen Python-Backend für das
Regenradar.

Repo-Layout:
- `WeatherMat/` – iOS-App (Swift 6, SwiftUI, `@Observable`, strukturierte
  Nebenläufigkeit).
- `WeatherMatWatch/` – watchOS-Companion-App (eigenes WeatherKit-Fetching,
  Complication).
- `WeatherMatWidgets/` – Home-Screen-Widgets + Live Activities (Regenradar-
  Countdown, Unwetterwarnung).
- `WeatherMatShared/` – von App und Widgets gemeinsam genutzte
  `ActivityAttributes`-Typen für Live Activities.
- `WeatherMatTests/` – Unit-Tests (Swift Testing Framework).
- `RadarProxy/` – eigenständiger FastAPI/Python-Dienst (`app.py`, ~2370
  Zeilen) für DWD-Radardaten; läuft auf einem netcup-VPS und als zweite
  Instanz als Home-Assistant-Add-on (lokal mit externem Fallback).

Git-Status: Hauptbranch `main`, aktuell mehrere unversionierte/uncommittete
Änderungen (siehe Abschnitt 9) – u. a. die kompletten Radar-Performance-
Optimierungen aus dieser Session sowie bereits vor dieser Session
bestehende, noch nicht committete Features (Gezeiten/Wassertemperatur,
Live Activities, Widgets, App Intents, iPad-Sidebar).

## 2. Gesamtarchitektur

MVVM-artig, mit `WeatherViewModel` (`WeatherMat/ViewModels/WeatherViewModel.swift`,
~570 Zeilen, `@Observable`, per `@Environment` an die View-Hierarchie
injiziert) als zentralem State-Container. Es ist laut bestehendem Audit ein
"God Object": Wetterladen/-cachen, GPS, Standortliste, Radar-Prewarming,
Where2Go, Tagesauswahl, Swipe-zwischen-Orten und Persistenz sitzen alle in
einer Klasse (Sections: Weather data, Location state, Services, Load
weather, Refresh, Foreground refresh + radar prewarm, Location management,
Day selection, GPS, Swipe between locations, Persistence).

Navigation (`ContentView.swift`): `horizontalSizeClass == .regular` (iPad)
→ `NavigationSplitView` mit permanenter Sidebar (`LocationsView`); sonst
(iPhone) → `WeatherView` + `LocationsView` als Sheet.

Services sind größtenteils statische `enum`/Singleton-APIs (kein
Dependency Injection):
- **Wetterdaten:** `OpenMeteoService`, `WeatherKitService`, `BrightSkyService`,
  `AirQualityService`, `WaterTemperatureService`, `EnsembleService`
  (gewichtet/kombiniert alle Quellen zu `EnsembleWeatherData`, inkl.
  Modell-Disagreement-Anzeige als Temperaturspanne an unsicheren Tagen).
- **Lokale Station:** `NetatmoService` (OAuth2, Keychain-Token).
- **Standort/Geo:** `LocationService`, `GeocodingService`.
- **Radar:** `RainRadarService`, `RegionPackService` (Details: Abschnitt 4).
- **Persistenz:** `WeatherCacheStore` (UserDefaults-Cache, von
  `WeatherViewModel` **und** von App-Intents-Hintergrundausführungen
  gemeinsam genutzt, damit beide dasselbe JSON-Format schreiben/lesen),
  `ForecastCalibrationStore`.
- **Sonstiges:** `Where2GoService` (Ausflugsziel-Vorschläge),
  `PushRegistrationService` (APNs-Registrierung beim Radar-Proxy),
  `NotificationService`, `WatchConnectivityService`, `LiveActivityController`
  (startet/aktualisiert/beendet die zwei Live Activities: Radar-Countdown,
  Unwetterwarnung).

`WeatherMat/AppIntents/` (App Shortcuts/Siri): `FindGoodWeatherIntent`,
`RefreshWeatherIntent`, `SavedLocationEntity`, `WeatherMatShortcuts` – laufen
außerhalb des Lebenszyklus des ViewModels, lesen/schreiben daher direkt über
`WeatherCacheStore`.

## 3. Wetter-Datenfluss (nicht Radar)

```
OpenMeteo / WeatherKit / BrightSky / AirQuality / WaterTemperature / Netatmo
        │
        ▼
EnsembleService  (gewichtete Kombination je nach Horizont/Modellgüte,
                  Temperaturspanne bei geringer Modell-Übereinstimmung)
        │
        ▼
WeatherViewModel  (Cache via WeatherCacheStore, GPS via LocationService,
                   Radar-Prewarming-Trigger, Standortliste)
        │
        ▼
WeatherView  (Hero, Hourly, Daily, Stats, RainBanner, Where2Go,
              WaterTemperatureView, TopBar)
```

Diese Datenflüsse waren **nicht** Gegenstand der Optimierungen in dieser
Session (Fokus lag ausschließlich auf dem Regenradar).

## 4. Radar: Architektur nach den Optimierungen dieser Session

### 4.1 Ende-zu-Ende-Datenfluss

```
DWD Open Data (Radar-Composite + ICON-EU WMS/GRIB)
        │
        ▼
RadarProxy (Python/FastAPI, app.py)
  - lädt/dekodiert Radar- & Modelldaten (numpy/PIL)
  - rendert PNG-Kacheln on-demand + Cache (RAM + Disk)
  - baut "Region-Pack" (Binärformat), jetzt zeitfenster-begrenzt (4.3)
  - Warm-Loops (Hintergrund-Threads) für Hotspots/Nutzer-Standorte
        │  HTTP (timeline.json / tiles/*.png / region-pack)
        ▼
RainRadarService (iOS)   → Timeline laden, 30-Min-Cache
RegionPackService (iOS)  → Region-Pack laden + dekodieren, inkl. Zeitfenster
        │
        ▼
RadarV2Store (@Observable)  → Timeline-/Playback-Zustand, Frame-Auswahl,
                               Render-Fenster-Berechnung (4.2)
        │
        ▼
RegionPackController (@Observable)  → Laden + inkrementelles Rendern,
                                       vollständig ereignisgesteuert (4.2)
        │
        ▼
RainRadarScreen (View)  → orchestriert Controller/Store, Chrome-Logik
        │
        ├─► RadarRegionImageRenderer  → Accelerate/vImage-Pipeline (4.4)
        │
        └─► RadarV2MapView (MKMapView)  → Region-Overlay oder Tile-Fallback,
                                           debounced Pan/Zoom (4.5)
        │
        └─► RadarTimelineControl  → lokal entkoppelter, throttled Scrubber (4.6)
```

### 4.2 Ereignisgesteuerte Lade-/Render-Architektur (vorher: 220ms-Polling)

Früher lief eine permanente `while !Task.isCancelled { …; sleep(220ms) }`-
Schleife in `RainRadarView.swift`, die ständig neu prüfte, welche Frames
gebraucht werden. Das ist vollständig ersetzt:

- **`RegionPackController`** (neu, `WeatherMat/Views/Weather/Radar/RegionPackController.swift`)
  kapselt Laden + inkrementelles Rendern. `ensureRendered(...)` macht **einen
  einzigen begrenzten Durchlauf** pro Aufruf (fehlende Frames rendern,
  fertig) statt zu pollen. `covers(windowStart:windowEnd:)` prüft anhand der
  tatsächlich vom Server gelieferten Zeitspanne, ob ein Reload nötig ist –
  eine einzelne fehlende Frame-ID innerhalb eines abgedeckten Fensters löst
  **keinen** Reload-Loop aus (echte Datenlücken sind nur eine Render-Lücke,
  kein Trigger).
- **`RadarV2Store`** cached die Readiness-Lookup-Map
  (`regionFrameIDToTimelineFrameID`) jetzt einmalig beim Timeline-Laden statt
  bei jeder Plan-Berechnung neu zu bauen; `regionRenderWindow(radius:)`
  liefert die Frames, die aktuell gerendert gehalten werden sollen.
- **Trigger statt Timer:** `onChange(of: store.selectedFrame)` (90ms
  Debounce – ein einzelner `sleep`+Check, keine Schleife) für
  Scrubben/Playback/Timeline-Erstladung; `onChange(of: regionController.pack)`
  für "Pack fertig geladen"; Kartenbewegungen bleiben über das in
  `RadarV2MapView.Coordinator` vorhandene (jetzt 300ms-)Debounce
  ereignisgesteuert (4.5).
- **`onDisappear`** ruft `regionController.cancelAll()` plus Abbruch aller
  lokalen Debounce-Tasks – kein Task läuft weiter, wenn der Radar-Screen
  nicht sichtbar ist.

### 4.3 Backend-Zeitfenster statt "alles" (Datenmenge/Netzwerk)

`RadarProxy/app.py`, Endpunkt `/region-pack`:
- Akzeptiert jetzt `start_time`/`end_time` (ISO8601). Ohne Angabe gilt ein
  gleitendes Default-Fenster: letzte 2h + nächste 1h um "jetzt"
  (`REGION_PACK_DEFAULT_PAST_HOURS`/`_FUTURE_HOURS`, env-konfigurierbar).
  `frames=all` bleibt als expliziter Opt-out für den vollen Datensatz
  (z. B. Debugging) erhalten.
- `_build_region_pack` filtert bei gesetztem Fenster; ohne Fenster-Argumente
  (z. B. bestehende Unit-Tests, die die Funktion direkt aufrufen) bleibt das
  alte Verhalten unverändert – keine Breaking Changes für Code, der die
  interne Funktion direkt nutzt.
- Client (`RegionPackService.swift`) schickt `start_time`/`end_time`,
  abgeleitet aus `store.regionRenderWindow(radius:)` (dem tatsächlich aktiv
  sichtbaren Zeitfenster), statt wie zuvor pauschal die komplette Timeline
  (inkl. bis zu 120h Vorhersage) anzufordern.
- **8 neue Backend-Tests** (`test_radar_core.py`) + ein eigenes
  End-to-End-HTTP-Checkscript gegen den echten Endpunkt decken Fenster-
  Filterung, Defaults und 400/404-Fehlerfälle ab.

### 4.4 Pixel-Rendering: Accelerate/vImage statt Swift-Schleifen

`RadarRegionOverlay.swift` – komplett umgebaut:
- 256-Einträge-Lookup-Tabelle (statt Palette-Suche pro Pixel) pro Frame,
  angewendet via `vImageTableLookUp_Planar8` auf das gesamte Grid in einem
  vektorisierten Aufruf (Regen- und optional Schnee-Kanal getrennt, dann per
  0/255-Maske kombiniert).
- Weichzeichnung (Feathering) über `vImageBoxConvolve_Planar8` mit
  `kvImageTruncateKernel` statt vier verschachtelter Swift-Loops.
- Zusammensetzen zu `CGImage` via `vImageConvert_Planar8toARGB8888`.
- Läuft weiterhin komplett in `Task.detached(priority: .utility)`, nie auf
  dem MainActor.
- **Verifiziert:** Pixel-genauer Unit-Test (`regionRendererAppliesRainCutoffButPaintsSnowTrace`)
  grün; zusätzlich per eigenem Vergleichsskript gegen die alte Implementierung
  geprüft – bit-identisch ohne Feathering, mit Feathering nur ±1–3/255
  Alpha-Abweichung (Rundung statt Trunkierung, visuell nicht wahrnehmbar).
  Auf einem 384×384-Grid ca. 7,5–8× schneller (Single-Thread-Messung).

### 4.5 Map-Pan/Zoom-Debounce

`RadarMapView.swift`:
- Settle-Debounce nach Pan/Zoom von 180ms auf 300ms erhöht (betrifft
  Tile-Overlay-Swap, Region-Overlay-Swap **und** den Region-Pack-Reload-
  Trigger via `onRegionSettled`).
- Zusätzlicher separater 300ms-Debounce speziell für den Tile-Prefetch-
  Trigger aus `update()` (feuerte vorher bei jedem SwiftUI-Re-Render, z. B.
  bei jedem einzeln veröffentlichten gerenderten Frame, potenziell Dutzende
  Male während einer aktiven Geste).

### 4.6 Scrubber: lokal entkoppelt + throttled

`RadarTimelineControl.swift`:
- Lokaler `@State private var liveDragIndex: Int?` – Knopf/Ticks folgen
  beim Ziehen sofort (`effectiveIndex`), aber nur **diese** Control
  re-rendert sich dabei, nicht `RainRadarScreen` samt Karte.
- Das externe `selectedIndex`-Binding (treibt `store.selectedIndex`, Map
  und Region-Pack-Rendering) wird nur alle 80ms committet statt bei jedem
  Pixel; beim Loslassen wird exakt final committet (kein Zurückschnappen).
- Tick-Label/Sichtbarkeits-Berechnung (`Calendar.dateComponents`,
  Datumsformatierung) läuft nicht mehr pro sichtbarem Tick bei jeder
  Body-Auswertung, sondern einmalig in `init` vorberechnet
  (`computeTickDisplay`) und zur Laufzeit nur noch per O(1)-Array-Lookup
  gelesen.
- **2 neue Tests** decken die Vorberechnung ab (Bucket-Grenzen immer
  sichtbar, Schrittweite ist bucket-lokal, nicht global).

### 4.7 Noch nicht angegangen (aus dem ursprünglichen Performance-Audit)

- `RainRadarScreen` ist nach wie vor eine recht große View mit viel
  Orchestrierungslogik (Chrome-Sichtbarkeit, Notices) – jetzt aber mit
  Lade-/Render-Logik sauber in `RegionPackController` ausgelagert.
- Starke Kopplung an Singletons (`.shared`) bleibt projektweit bestehen
  (betrifft nicht nur Radar).

## 5. Watch-App, Widgets, Live Activities, App Intents

- **`WeatherMatWatch/`** – eigenständige watchOS-App, eigenes WeatherKit-
  Fetching (`WeatherKitFetcher`), Standort-Sync vom iPhone
  (`LocationSyncReceiver`/`WatchConnectivityService`), Complication
  (`WeatherTimelineProvider`).
- **`WeatherMatWidgets/`** + **`WeatherMatShared/`** – zwei Live Activities:
  Regenradar-Countdown und Unwetterwarnung (`LiveActivityController` auf
  App-Seite startet/aktualisiert/beendet sie).
- **`WeatherMat/AppIntents/`** – Siri/Shortcuts-Integration: Wetter
  aktualisieren, "gutes Wetter finden" (nutzt `Where2GoService`-Logik),
  `SavedLocationEntity` für App-Intents-Parameter.

Diese Bereiche waren **nicht** Gegenstand der Optimierungen dieser Session
und sind unabhängig vom Radar-Feature.

## 6. Backend (`RadarProxy/app.py`) – Gesamtbild

- FastAPI/Uvicorn, numpy+PIL für Bildverarbeitung, `ThreadPoolExecutor`/
  Threads für Warm-Loops (GIL wird bei numpy/PIL-Operationen freigegeben).
- Mehrstufiges Caching: In-Memory-Tile-Cache, Disk-Cache, Region-Pack-Cache
  (max. 24 Einträge, Cache-Key enthält jetzt auch das Zeitfenster, siehe
  4.3).
- Hintergrund-"Warm"-Mechanismus rendert proaktiv Kacheln für Hotspots &
  registrierte Nutzer-Standorte.
- APNs-Push für Unwetterwarnungen (`_poll_warnings_once`, env-gesteuert
  Sandbox/Production).
- **Tests:** `test_radar_core.py`, 29 Tests (21 bestehend + 8 neu aus
  dieser Session), lokal ausführbar via
  `python3 -m venv .venv && .venv/bin/pip install fastapi numpy pillow
  pydantic httpx && .venv/bin/python -m unittest test_radar_core -v`
  (eccodes/uvicorn nicht nötig für die Tests, da lazy importiert).

## 7. Diese Session: Was konkret optimiert wurde

Alle vier Teilaufgaben eines mehrstufigen Performance-Auftrags, nacheinander
umgesetzt und jeweils mit Build + vollständiger Test-Suite verifiziert:

1. **Pixel-Rendering** (`RadarRegionOverlay.swift`) → Accelerate/vImage
   (Abschnitt 4.4).
2. **Polling-Schleife entfernt** (`RainRadarView.swift`,
   `RegionPackController.swift` neu, `RadarV2Store.swift`) → ereignisgesteuert
   (Abschnitt 4.2).
3. **Netzwerk-Overfetching** (`RadarProxy/app.py`, `RegionPackService.swift`,
   `RadarMapView.swift`) → Zeitfenster + Pan/Zoom-Debounce (Abschnitte 4.3,
   4.5).
4. **Scrubber-Performance** (`RadarTimelineControl.swift`) → lokal
   entkoppelt + throttled, Tick-Vorberechnung (Abschnitt 4.6).

Alle vier Punkte adressieren direkt die im ursprünglichen
`WeatherMat_Radar_Overview.md` identifizierten Hotspots.

## 8. Tests – Gesamtstand

- **Swift:** `WeatherMatTests` – 28 Tests (Swift Testing Framework), alle
  grün: `EnsembleLogicTests`, `RadarLogicTests` (12, davon 6 neu/erweitert
  in dieser Session), `WeatherMatSwiftTesting` ("WeatherMat core
  behavior").
- **Python:** `RadarProxy/test_radar_core.py` – 29 Tests, alle grün.
- Build verifiziert via `xcodebuild -scheme WeatherMat -destination
  'platform=iOS Simulator,name=iPhone 17e'` (Debug, build + test).

## 9. Aktueller Repo-Status

Nichts aus dieser Session ist committet. `git status --short` (Kurzfassung):

```
M  RadarProxy/app.py
M  RadarProxy/test_radar_core.py
M  WeatherMat.xcodeproj/project.pbxproj
M  WeatherMat/Services/RainRadarService.swift
M  WeatherMat/Services/RegionPackService.swift
M  WeatherMat/Views/Weather/Radar/RadarMapView.swift
M  WeatherMat/Views/Weather/Radar/RadarRegionOverlay.swift
M  WeatherMat/Views/Weather/Radar/RadarTimelineControl.swift
M  WeatherMat/Views/Weather/Radar/RadarV2Store.swift
M  WeatherMat/Views/Weather/RainRadarView.swift
M  WeatherMatTests/RadarLogicTests.swift
?? WeatherMat/Views/Weather/Radar/RegionPackController.swift
```

Daneben existieren **vor dieser Session** bereits unversionierte Änderungen
(nicht Teil der Radar-Arbeit): `WeatherMat/AppIntents/`,
`WeatherMat/Services/LiveActivityController.swift`,
`WeatherMat/Services/WeatherCacheStore.swift`, `WeatherMatShared/`,
`WeatherMatWidgets/`, sowie Änderungen an `WeatherViewModel.swift`,
`PushRegistrationService.swift` u. a. (Gezeiten-/Wassertemperatur-Feature,
Live Activities, App Intents, iPad-Sidebar – siehe Commit-Historie
`80a5e6a`, `d3cf8db`, `6994bc9`).

## 10. Relevante Dateien für eine Weiterarbeit/KI-Analyse

Radar-Client: `RadarMapView.swift`, `RadarRegionOverlay.swift`,
`RainRadarView.swift`, `RadarV2Store.swift`, `RegionPackController.swift`,
`RadarTimelineControl.swift`, `RegionPackService.swift`,
`RainRadarService.swift`.
Radar-Backend: `RadarProxy/app.py`.
Allgemeine Architektur: `WeatherViewModel.swift`, `ContentView.swift`,
`WeatherView.swift`.
Bestehende Dokumente: `WeatherMat_Audit.md` (allgemeines Code-Audit),
`WeatherMat_Radar_Overview.md` (historisch – Zustand vor dieser Session).
