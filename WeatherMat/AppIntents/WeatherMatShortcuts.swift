// WeatherMatShortcuts.swift
// Registers WeatherMat's App Intents as system-discoverable App Shortcuts
// (Siri, Spotlight, Shortcuts app). No Info.plist entries needed — the
// system reads this at launch from the compiled AppIntents metadata.
//
// Phrases deliberately avoid the generic "wie/wo ist das Wetter" pattern:
// Siri treats plain weather queries as a reserved system domain answered by
// Apple's own Weather engine, regardless of the app name in the phrase — a
// third-party AppShortcut simply never gets a chance to match. Framing the
// phrase around "Ausflugsziel"/"sonniges Ziel" (WeatherMat's own "Wohin?"
// feature) avoids that collision.
//
// `RefreshWeatherIntent` (iOS 27-only) is deliberately NOT listed here:
// `@AppShortcutsBuilder` doesn't support mixing an `if #available` branch
// with an unconditional `AppShortcut` in the same list (the conditional
// branch builds as `[AppShortcut]`, which doesn't type-check against the
// builder's per-item `AppShortcut` variadic block). Since an app may only
// have one `AppShortcutsProvider`, and this provider must also work on
// pre-27 OS versions for `FindGoodWeatherIntent`, the safe option is to
// leave `RefreshWeatherIntent` off the Siri-phrase catalog. It's still a
// perfectly usable `AppIntent` — findable and runnable from the Shortcuts
// app's action library — just without a predefined Siri phrase.
import AppIntents

struct WeatherMatShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: FindGoodWeatherIntent(),
            phrases: [
                "Finde ein sonniges Ausflugsziel mit \(.applicationName)",
                "\(.applicationName), wohin soll ich fahren",
                "\(.applicationName) Ausflugsziel finden"
            ],
            shortTitle: "Ausflugsziel finden",
            systemImageName: "sun.max"
        )
    }
}
