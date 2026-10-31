// WeatherMatWidgetsBundle.swift
import WidgetKit
import SwiftUI

@main
struct WeatherMatWidgetsBundle: WidgetBundle {
    var body: some Widget {
        RainRadarLiveActivityWidget()
        WeatherWarningLiveActivityWidget()
    }
}
