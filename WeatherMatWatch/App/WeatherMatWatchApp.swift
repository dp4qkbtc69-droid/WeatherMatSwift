// WeatherMatWatchApp.swift
import SwiftUI

@main
struct WeatherMatWatchApp: App {
    @State private var vm = WatchWeatherViewModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(vm)
        }
        // ContentView's .task only fires once per view lifetime, so
        // reopening the app from the background (not a fresh relaunch)
        // never re-triggered a fetch. Mirrors WeatherMatApp's iPhone-side
        // scenePhase handling.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await vm.refresh() }
            }
        }
    }
}
