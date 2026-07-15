// ContentView.swift
import SwiftUI

struct ContentView: View {
    @Environment(WatchWeatherViewModel.self) private var vm
    @State private var showingLocationPicker = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 6) {
                    if let snapshot = vm.snapshot {
                        Image(systemName: snapshot.sfSymbol)
                            .font(.system(size: 34))
                            .symbolRenderingMode(.multicolor)

                        Text("\(snapshot.currentTemp)°")
                            .font(.system(size: 40, weight: .semibold))

                        Text(snapshot.conditionLabel)
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 14) {
                            Label("\(snapshot.highTemp)°", systemImage: "arrow.up")
                            Label("\(snapshot.lowTemp)°", systemImage: "arrow.down")
                        }
                        .font(.subheadline)
                        .padding(.top, 2)

                        Divider().padding(.vertical, 4)

                        Label(snapshot.rainSummary, systemImage: snapshot.rainSFSymbol)
                            .font(.footnote)
                            .multilineTextAlignment(.center)

                        Text("Stand: \(snapshot.fetchedAt.formatted(date: .omitted, time: .shortened))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .padding(.top, 2)
                    } else if vm.isLoading {
                        ProgressView()
                            .padding(.top, 40)
                    } else {
                        Text(vm.errorMessage ?? "Keine Daten")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.top, 40)
                    }
                }
                .padding(.horizontal)
                .frame(maxWidth: .infinity)
            }
            .refreshable { await vm.refresh() }
            .navigationTitle(vm.selectedLocationName)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingLocationPicker = true
                    } label: {
                        Image(systemName: "list.bullet")
                    }
                }
            }
            .sheet(isPresented: $showingLocationPicker) {
                LocationPickerView()
            }
            .task { await vm.refreshOnAppear() }
        }
    }
}
