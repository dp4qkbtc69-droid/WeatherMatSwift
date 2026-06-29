// WeatherModels+Codable.swift
// Full explicit Codable for types where auto-synthesis can't work (UUID id fields, cross-file)
import Foundation

// MARK: - HourlyEntry (exclude auto-generated id)
extension HourlyEntry {
    enum CodingKeys: String, CodingKey {
        case time, temp, condition, precipitationProbability, precipitationMm, windSpeed, isDay
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        time                     = try c.decode(Date.self,         forKey: .time)
        temp                     = try c.decode(Int.self,          forKey: .temp)
        condition                = try c.decode(WMOCondition.self,  forKey: .condition)
        precipitationProbability = try c.decode(Int.self,          forKey: .precipitationProbability)
        precipitationMm          = try c.decode(Double.self,       forKey: .precipitationMm)
        windSpeed                = try c.decode(Int.self,          forKey: .windSpeed)
        isDay                    = try c.decode(Bool.self,         forKey: .isDay)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(time,                      forKey: .time)
        try c.encode(temp,                      forKey: .temp)
        try c.encode(condition,                 forKey: .condition)
        try c.encode(precipitationProbability,  forKey: .precipitationProbability)
        try c.encode(precipitationMm,           forKey: .precipitationMm)
        try c.encode(windSpeed,                 forKey: .windSpeed)
        try c.encode(isDay,                     forKey: .isDay)
    }
}

// MARK: - DailyEntry (exclude auto-generated id)
extension DailyEntry {
    enum CodingKeys: String, CodingKey {
        case date, condition, high, low, precipitationProbability
        case precipitationSum, sunrise, sunset, uvMax, windMax, sunshineDuration
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date                     = try c.decode(Date.self,         forKey: .date)
        condition                = try c.decode(WMOCondition.self,  forKey: .condition)
        high                     = try c.decode(Int.self,          forKey: .high)
        low                      = try c.decode(Int.self,          forKey: .low)
        precipitationProbability = try c.decode(Int.self,          forKey: .precipitationProbability)
        precipitationSum         = try c.decode(Double.self,       forKey: .precipitationSum)
        sunrise                  = try c.decode(Date.self,         forKey: .sunrise)
        sunset                   = try c.decode(Date.self,         forKey: .sunset)
        uvMax                    = try c.decode(Double.self,       forKey: .uvMax)
        windMax                  = try c.decode(Int.self,          forKey: .windMax)
        sunshineDuration         = try c.decodeIfPresent(Double.self, forKey: .sunshineDuration) ?? 0
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(date,                      forKey: .date)
        try c.encode(condition,                 forKey: .condition)
        try c.encode(high,                      forKey: .high)
        try c.encode(low,                       forKey: .low)
        try c.encode(precipitationProbability,  forKey: .precipitationProbability)
        try c.encode(precipitationSum,          forKey: .precipitationSum)
        try c.encode(sunrise,                   forKey: .sunrise)
        try c.encode(sunset,                    forKey: .sunset)
        try c.encode(uvMax,                     forKey: .uvMax)
        try c.encode(windMax,                   forKey: .windMax)
        try c.encode(sunshineDuration,          forKey: .sunshineDuration)
    }
}

// MARK: - CurrentWeather
extension CurrentWeather {
    enum CodingKeys: String, CodingKey {
        case temp, feelsLike, humidity, cloudCover, windSpeed, windDirection
        case pressure, visibility, uvIndex, isDay, precipitation, airQuality, stationObservation, stationObservations, condition, background
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        temp          = try  c.decode(Int.self,               forKey: .temp)
        feelsLike     = try  c.decode(Int.self,               forKey: .feelsLike)
        humidity      = try  c.decode(Int.self,               forKey: .humidity)
        cloudCover    = try  c.decodeIfPresent(Int.self,      forKey: .cloudCover) ?? 50
        windSpeed     = try  c.decode(Int.self,               forKey: .windSpeed)
        windDirection = try  c.decode(Int.self,               forKey: .windDirection)
        pressure      = try  c.decode(Int.self,               forKey: .pressure)
        visibility    = try  c.decode(Int.self,               forKey: .visibility)
        uvIndex       = try  c.decode(Double.self,            forKey: .uvIndex)
        isDay         = try  c.decode(Bool.self,              forKey: .isDay)
        precipitation = try  c.decode(Double.self,            forKey: .precipitation)
        airQuality    = try  c.decodeIfPresent(AirQuality.self, forKey: .airQuality)
        stationObservation = try c.decodeIfPresent(NetatmoObservation.self, forKey: .stationObservation)
        stationObservations = try c.decodeIfPresent([NetatmoObservation].self, forKey: .stationObservations) ?? stationObservation.map { [$0] } ?? []
        condition     = try  c.decode(WMOCondition.self,       forKey: .condition)
        background    = try  c.decode(WeatherBackground.self,  forKey: .background)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(temp,          forKey: .temp)
        try c.encode(feelsLike,     forKey: .feelsLike)
        try c.encode(humidity,      forKey: .humidity)
        try c.encode(cloudCover,    forKey: .cloudCover)
        try c.encode(windSpeed,     forKey: .windSpeed)
        try c.encode(windDirection, forKey: .windDirection)
        try c.encode(pressure,      forKey: .pressure)
        try c.encode(visibility,    forKey: .visibility)
        try c.encode(uvIndex,       forKey: .uvIndex)
        try c.encode(isDay,         forKey: .isDay)
        try c.encode(precipitation, forKey: .precipitation)
        try c.encodeIfPresent(airQuality, forKey: .airQuality)
        try c.encodeIfPresent(stationObservation, forKey: .stationObservation)
        try c.encode(stationObservations, forKey: .stationObservations)
        try c.encode(condition,     forKey: .condition)
        try c.encode(background,    forKey: .background)
    }
}

// MARK: - RainAnalysis
extension RainAnalysis {
    enum CodingKeys: String, CodingKey {
        case type, text, sub, sfSymbol, confidence, minutesUntilRain, minutesUntilClear, chart
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type              = try c.decode(RainType.self,          forKey: .type)
        text              = try c.decode(String.self,            forKey: .text)
        sub               = try c.decode(String.self,            forKey: .sub)
        sfSymbol          = try c.decode(String.self,            forKey: .sfSymbol)
        confidence        = try c.decode(ConfidenceLevel.self,   forKey: .confidence)
        minutesUntilRain  = try c.decodeIfPresent(Int.self,      forKey: .minutesUntilRain)
        minutesUntilClear = try c.decodeIfPresent(Int.self,      forKey: .minutesUntilClear)
        chart             = try c.decodeIfPresent([RainChartPoint].self, forKey: .chart) ?? []
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type,              forKey: .type)
        try c.encode(text,              forKey: .text)
        try c.encode(sub,               forKey: .sub)
        try c.encode(sfSymbol,          forKey: .sfSymbol)
        try c.encode(confidence,        forKey: .confidence)
        try c.encodeIfPresent(minutesUntilRain,  forKey: .minutesUntilRain)
        try c.encodeIfPresent(minutesUntilClear, forKey: .minutesUntilClear)
        try c.encode(chart,             forKey: .chart)
    }
}

// MARK: - EnsembleWeatherData
extension EnsembleWeatherData {
    enum CodingKeys: String, CodingKey {
        case current, today, hourly, daily, rain, warnings
        case agreementPct, confidence, confidenceBands, activeModels
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        current      = try c.decode(CurrentWeather.self,    forKey: .current)
        today        = try c.decode(DailyEntry.self,        forKey: .today)
        hourly       = try c.decode([HourlyEntry].self,     forKey: .hourly)
        daily        = try c.decode([DailyEntry].self,      forKey: .daily)
        rain         = try c.decode(RainAnalysis.self,      forKey: .rain)
        warnings     = try c.decode([DWDWarning].self,      forKey: .warnings)
        agreementPct = try c.decode(Int.self,               forKey: .agreementPct)
        confidence   = try c.decode(ConfidenceLevel.self,   forKey: .confidence)
        confidenceBands = try c.decodeIfPresent([ForecastConfidenceBand].self, forKey: .confidenceBands) ?? []
        activeModels = try c.decode([String].self,          forKey: .activeModels)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(current,      forKey: .current)
        try c.encode(today,        forKey: .today)
        try c.encode(hourly,       forKey: .hourly)
        try c.encode(daily,        forKey: .daily)
        try c.encode(rain,         forKey: .rain)
        try c.encode(warnings,     forKey: .warnings)
        try c.encode(agreementPct, forKey: .agreementPct)
        try c.encode(confidence,   forKey: .confidence)
        try c.encode(confidenceBands, forKey: .confidenceBands)
        try c.encode(activeModels, forKey: .activeModels)
    }
}
