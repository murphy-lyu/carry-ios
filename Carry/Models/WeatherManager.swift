//
//  WeatherManager.swift
//  Carry
//
//  Requires: WeatherKit capability (Signing & Capabilities) +
//            com.apple.developer.weatherkit entitlement enabled in Developer Portal.
//

import Foundation
import Combine
import CoreLocation
import WeatherKit

// MARK: - DayWeatherInfo

/// 天气大类——从 WeatherKit `WeatherCondition` 归一的粗分类，供打包信号判断用，
/// 把 WeatherKit 类型隔离在 WeatherManager 内（spec: weather-aware-packing.md）。
enum WeatherCategory {
    case clear, cloudy, fog, wind, rain, snow, sleet, storm, other
}

/// Lightweight value type used by DestinationInfoView.
/// Keeps WeatherKit types isolated to WeatherManager only.
struct DayWeatherInfo: Identifiable {
    let id = UUID()
    let date: Date
    /// SF Symbol name for the weather condition
    let symbolName: String
    /// Already-formatted high temperature string (e.g. "24°") — 仅 UI 展示用
    let highTemp: String
    /// 信号提炼用的原始量（spec: weather-aware-packing.md）。摄氏统一存储，判断时与阈值比较；
    /// 展示仍用 `highTemp`（已按设备单位格式化）。
    let highC: Double
    let lowC: Double
    /// 降水概率 0...1
    let precipChance: Double
    let category: WeatherCategory
}

// MARK: - WeatherManager

@MainActor
final class WeatherManager: ObservableObject {

    // MARK: Published state

    /// Keyed by destination index; nil = not yet loaded; empty = failed / no data
    @Published private(set) var weatherByDestination: [Int: [DayWeatherInfo]] = [:]
    @Published private(set) var attribution: WeatherAttribution?

    // MARK: Private

    private struct CacheKey: Hashable {
        let lat: Double
        let lon: Double
        let dateString: String // yyyy-MM-dd
    }

    private var cache: [CacheKey: (data: [DayWeatherInfo], fetchedAt: Date)] = [:]
    private let cacheMaxAge: TimeInterval = 3 * 60 * 60 // 3 hours
    private let tempFormatter: MeasurementFormatter = {
        let f = MeasurementFormatter()
        f.numberFormatter.maximumFractionDigits = 0
        f.unitStyle = .short
        return f
    }()
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    // MARK: - Public API

    /// Fetches weather for all supplied destinations, refreshing stale cache entries.
    /// - Parameters:
    ///   - destinations: Array of (index, latitude, longitude) tuples (use the destinations array from DestinationInfoView).
    ///   - tripStartDate: Used to determine the number of days to display.
    ///   - tripEndDate: End of the trip.
    func fetchAll(destinations: [(index: Int, lat: Double, lon: Double)],
                  tripStartDate: Date,
                  tripEndDate: Date) {
        Task {
            // Load attribution once
            if attribution == nil {
                attribution = try? await WeatherService.shared.attribution
            }

            for dest in destinations {
                guard dest.lat != 0 else { continue }
                await fetchWeather(
                    destinationIndex: dest.index,
                    latitude: dest.lat,
                    longitude: dest.lon,
                    tripStartDate: tripStartDate,
                    tripEndDate: tripEndDate
                )
            }
        }
    }

    // MARK: - Private

    private func fetchWeather(destinationIndex: Int,
                               latitude: Double,
                               longitude: Double,
                               tripStartDate: Date,
                               tripEndDate: Date) async {
        let todayString = Self.dateFormatter.string(from: Date())
        let key = CacheKey(lat: latitude, lon: longitude, dateString: todayString)

        // Return from cache if still fresh
        if let cached = cache[key], Date().timeIntervalSince(cached.fetchedAt) < cacheMaxAge {
            weatherByDestination[destinationIndex] = cached.data
            return
        }

        do {
            let location = CLLocation(latitude: latitude, longitude: longitude)
            let weather = try await WeatherService.shared.weather(for: location)

            // Don't show weather for trips that end in the past
            let now = Date()
            guard tripEndDate >= now else {
                weatherByDestination[destinationIndex] = []
                return
            }

            let start = max(tripStartDate, now)
            let calendar = Calendar.current
            let days = weather.dailyForecast.filter { dayWeather in
                dayWeather.date >= calendar.startOfDay(for: start) &&
                dayWeather.date <= tripEndDate
            }

            let infos = days.prefix(7).map { day in
                DayWeatherInfo(
                    date: day.date,
                    symbolName: day.symbolName,
                    highTemp: tempFormatter.string(from: day.highTemperature),
                    highC: day.highTemperature.converted(to: .celsius).value,
                    lowC: day.lowTemperature.converted(to: .celsius).value,
                    precipChance: day.precipitationChance,
                    category: Self.category(for: day.condition)
                )
            }

            let result = Array(infos)
            cache[key] = (data: result, fetchedAt: Date())
            weatherByDestination[destinationIndex] = result

        } catch {
            // 失败原因记录到日志：可能是网络/WeatherKit 未启用/坐标无效等。
            // UI 仍按"空数组 = 无预报"显示（不引入新 UI 状态以控制改动范围）。
            CarryLogger.shared.log(.apiError,
                context: "weatherkit dest=\(destinationIndex) err=\(error.localizedDescription)")
            // 退化策略：有过期缓存则用；没有则空数组（卡片显示无内容）
            if let stale = cache[key] {
                weatherByDestination[destinationIndex] = stale.data
            } else {
                weatherByDestination[destinationIndex] = []
            }
        }
    }

    /// WeatherKit `WeatherCondition` → 粗分类。只区分打包信号关心的几类，其余归 `.other`。
    private static func category(for condition: WeatherCondition) -> WeatherCategory {
        switch condition {
        case .clear, .mostlyClear, .hot:
            return .clear
        case .cloudy, .mostlyCloudy, .partlyCloudy:
            return .cloudy
        case .foggy, .haze, .smoky:
            return .fog
        case .breezy, .windy:
            return .wind
        case .drizzle, .rain, .heavyRain, .sunShowers, .freezingDrizzle, .freezingRain:
            return .rain
        case .flurries, .snow, .heavySnow, .blowingSnow, .sunFlurries, .blizzard:
            return .snow
        case .sleet, .wintryMix, .hail:
            return .sleet
        case .thunderstorms, .strongStorms, .isolatedThunderstorms, .scatteredThunderstorms, .tropicalStorm, .hurricane:
            return .storm
        default:
            return .other
        }
    }
}
