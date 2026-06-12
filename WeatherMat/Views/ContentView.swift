// ContentView.swift
import SwiftUI

struct ContentView: View {
    @Environment(WeatherViewModel.self) private var vm
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @State private var showLocations = false

    var body: some View {
        Group {
            if hSizeClass == .regular {
                iPadLayout
            } else {
                iPhoneLayout
            }
        }
        .task {
            await vm.useGPSLocation()
        }
    }

    // MARK: - iPhone Layout
    private var iPhoneLayout: some View {
        ZStack {
            backgroundLayer
            WeatherView(showLocations: $showLocations)
        }
        .ignoresSafeArea()
        .sheet(isPresented: $showLocations) {
            LocationsView()
                .presentationBackground(.clear)
        }
    }

    // MARK: - iPad Layout
    private var iPadLayout: some View {
        NavigationSplitView {
            LocationsView()
                .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 380)
        } detail: {
            WeatherView(showLocations: $showLocations)
        }
        .background(backgroundLayer)
    }

    @ViewBuilder
    private var backgroundLayer: some View {
        let bg = vm.weatherData?.current.background ?? .sunny
        WeatherParticleView(background: bg)
            .animation(Animation.easeInOut(duration: 1.4), value: bg)
    }
}
