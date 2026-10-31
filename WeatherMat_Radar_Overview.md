# WeatherMat – Projekt- und Radar-Architektur-Überblick

Zweck dieses Dokuments: Kontext für eine KI-Analyse, mit Fokus auf die Performance
der Regenradar-Funktion. Stand: Code-Lesung ohne Änderungen (siehe auch das
bestehende allgemeine Audit `WeatherMat_Audit.md` im selben Verzeichnis).

## 1. Projekt im Überblick

**WeatherMat** ist eine SwiftUI-iOS-App (+ watchOS-Begleit-App + Widgets/Live
Activities) mit einem selbst betriebenen Python-Backend für das Regenradar.
Zwei Teile im Repo:

- `WeatherMat/` – iOS-App (Swift 6, SwiftUI, `@Observable`, strukturierte
  Nebenläufigkeit mit `async`/`await`, `withTaskGroup`, Actors).
- `RadarProxy/` – eigenständiger FastAPI/Python-Dienst (`app.py`, ca. 2284
  Zeilen), der DWD-Radardaten lädt, rendert, cached und per HTTP an die App
  ausliefert. Läuft sowohl auf einem netcup-VPS als auch als Home-Assistant-
  Add-on (lokal mit externem Fallback).
- Weitere App-Services (Netatmo, OpenMeteo, WeatherKit, Where2Go,
  Wetter-Cache) sind für die eigentliche Wetteranzeige zuständig, aber für die
  Radar-Performance nicht relevant.

## 2. Allgemeine App-Architektur

- MVVM-artig, aber `WeatherViewModel` (`WeatherMat/ViewModels/WeatherViewModel.swift`)
  ist laut bestehendem Audit ein "God Object" (~580 Zeilen: Wetterladen,
  Cache, GPS, Radar-Prewarming, Where2Go, Feedback).
- Services sind größtenteils statische `enum`/Singleton-APIs
  (`RainRadarService`, `RegionPackService`, …) – kein Dependency Injection,
  dafür einfache Call-Sites, aber schwer isoliert zu testen.
- Radar-UI ist der am saubersten separierte Teil: `RadarV2Store` ist ein
  eigener `@Observable`-Store (Timeline-/Playback-Zustand), getrennt von der
  View – im Gegensatz zu `RainRadarScreen`, wo View- und Geschäftslogik
  (Region-Pack-Laden, Chrome-Sichtbarkeits-Statemachine, Kachel-Prefetch)
  vermischt sind.

## 3. Radar: Ende-zu-Ende-Datenfluss

```
DWD Open Data (Radar-Composite + ICON-EU WMS/GRIB)
        │
        ▼
RadarProxy (Python/FastAPI, app.py)
  - lädt/dekodiert Radar- & Modell-Daten (numpy/PIL)
  - rendert PNG-Kacheln on-demand + Cache (RAM + Disk)
  - baut "Region-Pack" (eigenes Binärformat: JSON-Header + rohe Intensitäts-Bytes)
  - Warm-Loops (Hintergrund-Threads) für Hotspots/gespeicherte Orte
        │  HTTP (timeline.json / tiles/*.png / region-pack)
        ▼
RainRadarService (iOS)  → lädt Timeline, cached 30 Min in UserDefaults
RegionPackService (iOS) → lädt+dekodiert Region-Pack (Binärformat)
        │
        ▼
RadarV2Store (@Observable)  → Timeline-/Playback-Zustand, Frame-Auswahl
        │
        ▼
RainRadarScreen (View)  → orchestriert Region-Pack-Laden, Chrome-Logik, Prefetch
        │
        ├─► RadarRegionImageRenderer  → rendert Intensitäts-Bytes → CGImage (CPU, pro Pixel)
        │
        └─► RadarV2MapView (MKMapView via UIViewRepresentable)
                - zeigt entweder das vorgerenderte Region-Overlay (RadarRegionOverlay)
                - oder fällt auf einzelne MKTileOverlay-Kacheln vom Proxy zurück
                - zusätzlich optional DWD-WMS-Blitzdichte-Layer (live von maps.dwd.de)
        │
        └─► RadarTimelineControl  → Scrubber/Play-Button/Tagesreiter
```

### Zwei parallele Rendering-Pfade (wichtig für Performance-Analyse!)

1. **Region-Pack-Pfad** (Normalfall, nur DWD-Quelle, nur wenn Kartenausschnitt
   innerhalb des geladenen Pakets liegt): Server schickt Rohdaten, **Client
   rendert die Bilder selbst** pixelweise in Swift
   (`RadarRegionOverlay.swift`).
2. **Tile-Fallback-Pfad** (RainViewer-Fallback, oder wenn man aus dem
   Region-Pack-Ausschnitt herauszoomt/-pannt): klassische `MKTileOverlay`,
   Kacheln kommen fertig gerendert als PNG vom Server
   (`RadarMapView.swift`).

## 4. Konkrete Performance-relevante Stellen (Client)

**a) Pixel-Rendering in Swift statt GPU/Accelerate**
`RadarRegionOverlay.swift:72-168` – `paint()` und `featherAlpha()` laufen als
reine Swift-`for`-Loops über jedes Pixel (384×384 = ~147k Zellen pro Frame,
Faltung mit bis zu 3 Pässen für die Weichzeichnung). Läuft zwar in
`Task.detached(priority: .utility)`, ist aber dennoch deutlich teurer als eine
vektorisierte Lösung (vDSP/Accelerate oder Core Image/Metal-Shader). Für ~17
Frames im Render-Fenster (`regionRenderWindowRadius = 8`, also 17 Frames um
die Auswahl) läuft das wiederholt.

**b) Dauerschleife statt ereignisgesteuertem Rendering**
`RainRadarView.swift:296-355` – `loadRegionPack` enthält ein
`while !Task.isCancelled { … }`, das nach dem Rendern aller benötigten Frames
einfach alle 220 ms weiterpollt (`try? await Task.sleep(nanoseconds: 220_000_000)`),
solange der Radar-Screen offen ist. Das ist eine dauerhafte Hintergrund-
Schleife mit wiederholten `MainActor.run`-Hops, Dictionary-Rebuilds
(`regionRenderPlan`) und Objekt-Kopien – auch wenn nichts Neues zu tun ist.

**c) Request-Flut beim Pan/Zoom**
`RadarMapView.swift:475-535` – `RadarV2TilePrefetchPlan` lädt pro Frame bis zu
72 Kachel-URLs, für bis zu 10 "Nachbar-Frames" gleichzeitig (also potenziell
mehrere hundert parallele Requests) bei jeder Regionänderung. Zusätzlich wird
bei jedem `regionDidChangeAnimated` nach 180 ms ein komplett neuer
Region-Pack-Request ausgelöst (`RainRadarView.swift:370-388`).

**d) Server schickt immer den ganzen Timeline-Datensatz**
`RegionPackService.fetchRegionPack` fordert `frames=all` an
(`RegionPackService.swift:85`) – das Backend baut und schickt **alle** Frames
(Beobachtung + Nowcast + bis zu 120 h Vorhersage, Regen- und ggf.
Schnee-Kanal) in einem Binärpaket, auch wenn der Client im sichtbaren Fenster
nur ~17 davon rendert. Bei grid_size 384×384 Byte/Kanal × ggf. >100 Frames ist
das ein potenziell mehrere MB großes (gzip-komprimiertes) Payload pro
Kartenbewegung.

**e) SwiftUI-Timeline-Control**
`RadarTimelineControl.swift:159-191` – `ForEach` über alle `displayedFrames`
eines Tages (kann je nach Kadenz mehrere Dutzend bis >100 Einträge sein),
wobei pro Index bei jedem Re-Render `Calendar.current.dateComponents`
aufgerufen wird (`showLabel`). Der Scrubber per `DragGesture` ändert
`selectedIndex` kontinuierlich → löst bei jedem Pixel einen Re-Render der
gesamten Elternview (`RainRadarScreen.body`) inkl. `MKMapView`-`updateUIView`
aus.

**f) MapKit-Overlay-Choreografie**
Der `Coordinator` in `RadarV2MapView` verwaltet Crossfades zwischen
alter/neuer `MKTileOverlayRenderer` über `CATransaction` plus einen eigenen
`RadarTileReadinessCenter`-Actor für Readiness-Signale – funktional
nachvollziehbar, aber recht viel bewegliche Zustandslogik (mehrere parallele
Task-Objekte, Continuation-Verwaltung) für etwas, was MapKit selbst nicht
direkt unterstützt.

## 5. Backend (`RadarProxy/app.py`) – kurz relevant für Client-Performance

- FastAPI/Uvicorn, numpy+PIL für Bildverarbeitung, `ThreadPoolExecutor`/
  Threads für Warm-Loops (GIL wird bei numpy/PIL-Operationen freigegeben).
- Mehrstufiges Caching: In-Memory-Tile-Cache, Disk-Cache
  (`DISK_CACHE_MAX_AGE_SECONDS`), Region-Pack-Cache (max. 24 Einträge, Key aus
  lat/lon/km/grid/cache-Zeitstempel).
- Hintergrund-"Warm"-Mechanismus rendert proaktiv Kacheln für Hotspots &
  registrierte Nutzer-Standorte (`_warm_tiles_background`,
  `warm-locations`-Endpoint) – das ist, warum ein Kaltstart am Heimatort
  meist schnell ist, an einem neuen Ort aber ggf. live gerendert werden muss.
- `region-pack`-Endpoint baut bei Cache-Miss **immer alle** Frames auf einmal
  (`_build_region_pack`, Zeile ~987) – keine Möglichkeit für den Client, nur
  ein Zeitfenster anzufordern.
- Env-Parameter `DWD_RADAR_REGION_GRID_SIZE` (Default 384),
  `TILE_RENDER_SCALE` (Default 2, d.h. Kacheln werden intern in doppelter
  Auflösung gerendert).

## 6. Bereits bekannte strukturelle Probleme (aus `WeatherMat_Audit.md`, Priorität 3)

- `RainRadarScreen` mischt View + Geschäftslogik (kein eigener Store für
  Region-Pack-Laden/Chrome-State).
- Starke Kopplung an Singletons (`.shared`), kaum testbare Orchestrierung.
- Force-Unwraps bei URL-Konstruktion in allen Services (aktuell unkritisch,
  aber Codestil-Risiko).

## 7. Relevante Dateien (für die KI-Analyse mitgeben)

Client:
- `WeatherMat/Views/Weather/Radar/RadarMapView.swift`
- `WeatherMat/Views/Weather/Radar/RadarRegionOverlay.swift`
- `WeatherMat/Views/Weather/RainRadarView.swift`
- `WeatherMat/Views/Weather/Radar/RadarV2Store.swift`
- `WeatherMat/Views/Weather/Radar/RadarTimelineControl.swift`
- `WeatherMat/Services/RegionPackService.swift`
- `WeatherMat/Services/RainRadarService.swift`

Backend:
- `RadarProxy/app.py` (zumindest die `region-pack`-, `tile`- und
  Warm-Abschnitte)

## 8. Offene Frage für eine gezielte Analyse

Eine konkrete Beschreibung, **worin** sich die schlechte Performance zeigt
(ruckelige Wiedergabe/Playback? langsames erstes Laden? Hänger beim
Pan/Zoom? hoher Akkuverbrauch bei offenem Radar-Screen?) grenzt stark ein, ob
der Fokus auf (a) dem Swift-Pixel-Rendering, (b) der Dauerschleife/Polling,
(c) Netzwerk-Overfetching oder (d) der SwiftUI-Timeline liegen sollte.
