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

/// Lightweight value type used by DestinationInfoView.
/// Keeps WeatherKit types isolated to WeatherManager only.
struct DayWeatherInfo: Identifiable {
    let id = UUID()
    let date: Date
    /// SF Symbol name for the weather condition
    let symbolName: String
    /// Already-formatted high temperature string (e.g. "24°")
    let highTemp: String
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

            let infos = days.prefix(10).map { day in
                DayWeatherInfo(
                    date: day.date,
                    symbolName: day.symbolName,
                    highTemp: tempFormatter.string(from: day.highTemperature)
                )
            }

            let result = Array(infos)
            cache[key] = (data: result, fetchedAt: Date())
            weatherByDestination[destinationIndex] = result

        } catch {
            // On failure, use stale cache if available; otherwise mark as empty (card hidden)
            if let stale = cache[key] {
                weatherByDestination[destinationIndex] = stale.data
            } else {
                weatherByDestination[destinationIndex] = []
            }
        }
    }
}
