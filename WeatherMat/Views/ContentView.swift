// ContentView.swift
import SwiftUI

struct ContentView: View {
    @Environment(WeatherViewModel.self) private var vm
    @State private var showLocations = false

    var body: some View {
        ZStack {
            backgroundLayer
            WeatherView(showLocations: $showLocations)
        }
        .ignoresSafeArea()
        // Schriften skalieren mit den Systemeinstellungen, aber gedeckelt,
        // damit die Karten-Layouts nicht zerbrechen.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .sheet(isPresented: $showLocations) {
            LocationsView()
                .presentationBackground(.clear)
        }
        .task {
            await vm.useGPSLocation()
        }
    }

    @ViewBuilder
    private var backgroundLayer: some View {
        let bg = vm.weatherData?.current.background ?? .sunny
        WeatherParticleView(background: bg)
            .animation(Animation.easeInOut(duration: 1.4), value: bg)
    }
}
