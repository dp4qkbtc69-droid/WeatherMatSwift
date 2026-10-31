# WeatherMat – Code-Audit

Umfang: iOS-App (`WeatherMat/`), Watch-App + Widget (`WeatherMatWatch/`), Tests. Keine Code-Änderungen vorgenommen.

## Priorität 1 – Kritisch

**Client-Secrets im App-Bundle extrahierbar.** `LocalConfig.plist` ist zwar korrekt per `.gitignore` aus dem Repo ausgeschlossen (Dateirechte 600), wird aber zur Laufzeit über `Bundle.main` geladen (`NetatmoService.swift:149`, `GeocodingService.swift:27`, `RainRadarService.swift:245`) – das heißt, sie **muss** im ausgelieferten IPA enthalten sein, damit die App funktioniert. Jeder, der das IPA entpackt, kann `netatmoClientSecret`, `openWeatherMapGeocodingAPIKey` und `dwdRadarTileToken` im Klartext auslesen.
Besonders kritisch: der Netatmo-**Client-Secret** wird im OAuth2-`authorization_code`/`refresh_token`-Flow direkt aus der App heraus per POST verschickt (`NetatmoService.swift:180-199`). Ein confidential-client-Secret gehört grundsätzlich nicht in eine verteilte Mobile-App.
→ Empfehlung: Netatmo-Token-Austausch über einen eigenen Backend-Endpoint (z. B. den ohnehin vorhandenen RadarProxy) leiten, der das Secret serverseitig hält; die App bekommt nur das fertige Access-/Refresh-Token. Für den OpenWeatherMap-Key und den DWD-Radar-Token gilt dieselbe Empfehlung, hier ist die Auswirkung eines Leaks (Kontingent-Missbrauch) geringer, aber vermeidbar.

## Priorität 2 – Wichtig

**Kein Nutzer-Feedback bei fehlgeschlagener Netatmo-Anmeldung.** `SettingsActionRow` → `try? await NetatmoService.shared.authenticate()` (`LocationsView.swift:379`) verschluckt jeden Fehler (falsches Secret, Netzwerkausfall, User bricht ab) stillschweigend – der Spinner verschwindet, es passiert sichtbar nichts. Andere Fehlerzustände der App (Wetterladen) haben ein ordentliches Error-UI; hier fehlt das Pendant.

**37 parallele Netzwerk-Requests pro „Wohin?“-Abfrage.** `Where2GoService.candidateCoordinates` erzeugt Ursprung + 3 Ringe × 12 Richtungen = 37 Kandidaten, für die `findSpots` je einen eigenen Open-Meteo-Call auslöst (`Where2GoService.swift:75-94`, `119-133`). Funktioniert, ist aber unnötig netzwerk-/akkuintensiv und riskiert Rate-Limiting bei der kostenlosen Open-Meteo-API. Kandidatenzahl reduzieren oder über einen Batch-Endpoint bündeln.

**Force-Unwraps bei URL-Konstruktion.** Durchgängiges Muster `URLComponents(string: "...")!` / `c.url!` in praktisch allen Services (OpenMeteoService, GeocodingService, AirQualityService, BrightSkyService, NetatmoService, Where2GoService, PushRegistrationService, RegionPackService). Aktuell ungefährlich, da die Basis-Strings konstant sind, aber ein Codestil, der bei künftigen Änderungen (z. B. dynamisch zusammengesetzte Hosts) leicht zum Absturz führt. `guard let url = ... else { throw/return }` wäre robuster.

## Priorität 3 – Architektur

**`WeatherViewModel` ist ein „God Object“.** ~580 Zeilen, zuständig für Wetterladen, Cache, GPS, Standortliste, Radar-Prewarming, Where2Go und Feedback gleichzeitig. Für die vorgegebene MVVM-Architektur wäre eine Aufteilung sinnvoll, z. B. eigener `LocationsStore` und eine separate `RadarWarmupCoordinator`-Komponente, die `WeatherViewModel` injiziert bekommt statt alles selbst zu verwalten.

**`RainRadarScreen` (RainRadarView.swift, ~740 Zeilen) mischt View und Geschäftslogik.** Region-Pack-Laden, Chrome-Sichtbarkeits-Statemachine und Kachel-Prefetch-Steuerung leben direkt in der View statt in einem `@Observable`-Store (wie es `RadarV2Store` für die Timeline bereits vorbildlich macht). Auslagern würde Testbarkeit und Lesbarkeit verbessern.

**Doppelter Code:** `Array<NetatmoObservation>.preferredCalibrationObservation` ist identisch sowohl in `NetatmoService.swift` als auch in `EnsembleService.swift` definiert (private extension). Single Source of Truth herstellen (z. B. in `WeatherModels.swift`).

**`LocationService: ObservableObject`** ohne ein einziges `@Published`-Property und ohne dass irgendeine View sie tatsächlich observiert (Zugriff nur über `.shared`). Legacy-Konformität kann entfernt werden – konsistent mit der Projektregel „keine veralteten APIs“.

**Starke Kopplung an Singletons** (`.shared` bei nahezu allen Services). Erschwert Unit-Tests der ViewModel-Ebene; die vorhandenen Tests (`EnsembleLogicTests`, `RadarLogicTests`) testen deshalb konsequent nur pure Funktionen, nicht die Orchestrierung. Für neue Features ggf. Protokoll-Abstraktionen + Dependency Injection erwägen.

## Positiv hervorzuheben

- Durchgängig moderne SwiftUI-/Swift-6-Muster: `@Observable` statt `ObservableObject` (bis auf die eine genannte Ausnahme), strukturierte Nebenläufigkeit (`withTaskGroup`, `async let`), `Sendable`-Annotationen.
- Keine `http://`-Aufrufe, keine ATS-Ausnahmen in der Info.plist – TLS wird durchgehend erzwungen.
- Keine Secrets im Git-Repo; `LocalConfig.plist` korrekt `.gitignore`t und mit restriktiven Dateirechten.
- Netatmo-Token liegt in der Keychain (nicht UserDefaults), OAuth-Session nutzt `prefersEphemeralWebBrowserSession`.
- Defensive Patterns wie `Array.subscript(safe:)`, `[safe:]`-Decoding bei nullable API-Feldern, Migrations-sichere `Codable`-Implementierungen (`decodeIfPresent` + Fallback für neue Felder in gecachten Blobs).
- Gute Testabdeckung der eigentlichen Berechnungslogik (Ensemble-Gewichtung, Radar-Zeitfenster).
- Konsequente Accessibility-Labels/-Hints in den Views.

## Kleinere Punkte

- `WMOCode.condition(for:isDay:)` nimmt `isDay` entgegen, ignoriert es aber (Tag/Nacht-Unterscheidung passiert stattdessen separat über `sfSymbol(for:isDay:)` und einen manuellen `.nightClear`-Override in `EnsembleService`). Toter Parameter, verwirrend beim Lesen.
- `swiftlint:disable/enable line_length`-Kommentare in `WMOCode.swift`, obwohl kein `.swiftlint.yml` im Projekt existiert – wirkungslos, kann entfernt werden.
- Netatmo-Token-Keychain-Accessibility ist `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` statt `WhenUnlockedThisDeviceOnly` – nötig für Background-Refresh, aber bewusst dokumentieren, warum die schwächere Stufe gewählt wurde.
