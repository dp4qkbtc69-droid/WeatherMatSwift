// WMOCode.swift
import Foundation

struct WMOCondition {
    let code:           Int
    let label:          String
    let sfSymbol:       String       // day variant
    let sfSymbolNight:  String       // night variant
    let background:     WeatherBackground
}

extension WMOCondition: Codable {
    enum CodingKeys: String, CodingKey { case code }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self  = WMOCode.condition(for: try c.decode(Int.self, forKey: .code))
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(code, forKey: .code)
    }
}

enum WMOCode {
    static func condition(for code: Int, isDay: Bool = true) -> WMOCondition {
        table[code] ?? table[0]!
    }
    static func sfSymbol(for code: Int, isDay: Bool) -> String {
        let c = table[code] ?? table[0]!
        return isDay ? c.sfSymbol : c.sfSymbolNight
    }

    // swiftlint:disable line_length
    private static let table: [Int: WMOCondition] = [
         0: .init(code:  0, label: "Klarer Himmel",           sfSymbol: "sun.max.fill",           sfSymbolNight: "moon.stars.fill",        background: .sunny),
         1: .init(code:  1, label: "Überwiegend klar",        sfSymbol: "sun.max.fill",           sfSymbolNight: "moon.stars.fill",        background: .sunny),
         2: .init(code:  2, label: "Teilweise bewölkt",       sfSymbol: "cloud.sun.fill",         sfSymbolNight: "cloud.moon.fill",        background: .cloudy),
         3: .init(code:  3, label: "Bedeckt",                 sfSymbol: "cloud.fill",             sfSymbolNight: "cloud.fill",             background: .cloudy),
        45: .init(code: 45, label: "Neblig",                  sfSymbol: "cloud.fog.fill",         sfSymbolNight: "cloud.fog.fill",         background: .foggy),
        48: .init(code: 48, label: "Gefrierender Nebel",      sfSymbol: "cloud.fog.fill",         sfSymbolNight: "cloud.fog.fill",         background: .foggy),
        51: .init(code: 51, label: "Leichter Nieselregen",    sfSymbol: "cloud.drizzle.fill",     sfSymbolNight: "cloud.drizzle.fill",     background: .rainy),
        53: .init(code: 53, label: "Nieselregen",             sfSymbol: "cloud.drizzle.fill",     sfSymbolNight: "cloud.drizzle.fill",     background: .rainy),
        55: .init(code: 55, label: "Starker Nieselregen",     sfSymbol: "cloud.drizzle.fill",     sfSymbolNight: "cloud.drizzle.fill",     background: .rainy),
        61: .init(code: 61, label: "Leichter Regen",          sfSymbol: "cloud.rain.fill",        sfSymbolNight: "cloud.rain.fill",        background: .rainy),
        63: .init(code: 63, label: "Regen",                   sfSymbol: "cloud.rain.fill",        sfSymbolNight: "cloud.rain.fill",        background: .rainy),
        65: .init(code: 65, label: "Starker Regen",           sfSymbol: "cloud.heavyrain.fill",   sfSymbolNight: "cloud.heavyrain.fill",   background: .rainy),
        71: .init(code: 71, label: "Leichter Schneefall",     sfSymbol: "cloud.snow.fill",        sfSymbolNight: "cloud.snow.fill",        background: .snowy),
        73: .init(code: 73, label: "Schneefall",              sfSymbol: "cloud.snow.fill",        sfSymbolNight: "cloud.snow.fill",        background: .snowy),
        75: .init(code: 75, label: "Starker Schneefall",      sfSymbol: "cloud.snow.fill",        sfSymbolNight: "cloud.snow.fill",        background: .snowy),
        77: .init(code: 77, label: "Schneekörner",            sfSymbol: "cloud.snow.fill",        sfSymbolNight: "cloud.snow.fill",        background: .snowy),
        80: .init(code: 80, label: "Leichte Regenschauer",    sfSymbol: "cloud.sun.rain.fill",    sfSymbolNight: "cloud.moon.rain.fill",   background: .rainy),
        81: .init(code: 81, label: "Regenschauer",            sfSymbol: "cloud.sun.rain.fill",    sfSymbolNight: "cloud.moon.rain.fill",   background: .rainy),
        82: .init(code: 82, label: "Starke Regenschauer",     sfSymbol: "cloud.heavyrain.fill",   sfSymbolNight: "cloud.heavyrain.fill",   background: .rainy),
        85: .init(code: 85, label: "Schneeschauer",           sfSymbol: "cloud.snow.fill",        sfSymbolNight: "cloud.snow.fill",        background: .snowy),
        86: .init(code: 86, label: "Starke Schneeschauer",    sfSymbol: "cloud.snow.fill",        sfSymbolNight: "cloud.snow.fill",        background: .snowy),
        95: .init(code: 95, label: "Gewitter",                sfSymbol: "cloud.bolt.rain.fill",   sfSymbolNight: "cloud.bolt.rain.fill",   background: .stormy),
        96: .init(code: 96, label: "Gewitter mit Hagel",      sfSymbol: "cloud.bolt.rain.fill",   sfSymbolNight: "cloud.bolt.rain.fill",   background: .stormy),
        99: .init(code: 99, label: "Starkes Gewitter",        sfSymbol: "cloud.bolt.rain.fill",   sfSymbolNight: "cloud.bolt.rain.fill",   background: .stormy),
    ]
    // swiftlint:enable line_length
}
