// WeatherMatWatchApp.swift
import SwiftUI

@main
struct WeatherMatWatchApp: App {
    @State private var vm = WatchWeatherViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(vm)
        }
    }
}
