// ContentView.swift
import SwiftUI

struct ContentView: View {
    @Environment(WeatherViewModel.self) private var vm
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var showLocations = false
    // Starts collapsed — the app should open straight into the weather view,
    // not the location list. Reveal/hide happens via the system's own
    // sidebar-toggle control (there's no in-app nav bar for a custom toolbar
    // button to dock into, so the system one is the only reliable option).
    @State private var columnVisibility: NavigationSplitViewVisibility = .detailOnly

    var body: some View {
        Group {
            // iPad (regular width): permanent sidebar with the location list
            // instead of the iPhone's sheet + swipe-to-switch. iPhone/compact
            // width keeps the exact existing behaviour below, unchanged.
            if horizontalSizeClass == .regular {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    LocationsView(onClose: { columnVisibility = .detailOnly })
                } detail: {
                    ZStack {
                        // Background bleeds full-screen, but the weather
                        // content itself respects the top safe area here —
                        // unlike the iPhone layout there's no Dynamic Island
                        // to design a fixed offset around, so a hand-picked
                        // padding value would just fight the status bar on
                        // whichever iPad/orientation it wasn't tuned for.
                        backgroundLayer
                            .ignoresSafeArea()
                        WeatherView(
                            showLocations: $showLocations,
                            sidebarToggle: {
                                columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
                            }
                        )
                    }
                }
            } else {
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
        }
        // Schriften skalieren mit den Systemeinstellungen, aber gedeckelt,
        // damit die Karten-Layouts nicht zerbrechen.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .task {
            await vm.refreshOnLaunch()
        }
    }

    @ViewBuilder
    private var backgroundLayer: some View {
        let bg = vm.weatherData?.current.background ?? .sunny
        WeatherParticleView(background: bg)
            .animation(Animation.easeInOut(duration: 1.4), value: bg)
    }
}
