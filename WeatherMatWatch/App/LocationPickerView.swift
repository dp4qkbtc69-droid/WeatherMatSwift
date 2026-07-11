// LocationPickerView.swift
import SwiftUI

struct LocationPickerView: View {
    @Environment(WatchWeatherViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(vm.locations) { location in
                Button {
                    vm.selectLocation(location.id)
                    dismiss()
                } label: {
                    HStack {
                        if location.isGPS {
                            Image(systemName: "location.fill")
                        }
                        Text(location.name)
                        Spacer()
                        if location.id == vm.selectedLocationID {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    }
                }
            }
            .navigationTitle("Orte")
        }
    }
}
