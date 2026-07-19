//
//  MacGlobePanel.swift
//  Carry

#if targetEnvironment(macCatalyst)

import SwiftUI
import MapKit
import CoreLocation

/// Right-panel globe for the Mac split layout.
/// Mirrors the visited-data computation from HomeView; a future refactor
/// should extract this into TripStore to remove the duplication.
struct MacGlobePanel: View {
    @EnvironmentObject private var store: TripStore
    @AppStorage("mapStyleOption") private var mapStyleRaw: String = MapStyleOption.hybrid.rawValue

    private var mapStyleOption: MapStyleOption {
        MapStyleOption(rawValue: mapStyleRaw) ?? .hybrid
    }

    var body: some View {
        GlobeMapView(
            visitedCountries: visitedCountries,
            visitedCities: visitedCities,
            cityOpacity: 1.0,
            mapStyleOption: mapStyleOption,
            showUserLocation: false
        )
        .equatable()
        .ignoresSafeArea()
    }

    // MARK: - Data

    private var visitedCities: [VisitedCity] {
        var keyIndex: [String: Int] = [:]
        var cities: [VisitedCity] = []

        func addCoordinate(lat: Double, lon: Double, name: String = "") {
            guard lat != 0 else { return }
            let key = "\(Int(lat * 100)),\(Int(lon * 100))"
            if let idx = keyIndex[key] {
                if !name.isEmpty && cities[idx].cityName.isEmpty {
                    cities[idx] = VisitedCity(id: key, coordinate: cities[idx].coordinate, cityName: name)
                }
            } else {
                keyIndex[key] = cities.count
                cities.append(VisitedCity(id: key, coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon), cityName: name))
            }
        }

        for trip in store.trips where trip.countsAsVisited {
            var raw = [trip.destinationCity]
            for sep in [" and ", " And ", " AND ", " 和 "] { raw = raw.flatMap { $0.components(separatedBy: sep) } }
            for sep in [",", "，", "、", "/", "／", "&", "＆", "+", "＋"] { raw = raw.flatMap { $0.components(separatedBy: sep) } }
            let tokens = raw.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            addCoordinate(lat: trip.latitude, lon: trip.longitude, name: tokens.first ?? "")
            for (idx, dest) in trip.additionalDestinations.enumerated() {
                addCoordinate(lat: dest.latitude, lon: dest.longitude, name: (idx + 1) < tokens.count ? tokens[idx + 1] : "")
            }
        }
        return cities
    }

    private var visitedCountries: [VisitedCountry] {
        var best: [String: (lat: Double, lon: Double, date: Date)] = [:]

        func consider(code: String, lat: Double, lon: Double, date: Date) {
            guard !code.isEmpty, lat != 0 else { return }
            let normalized = normalizedCountryCode(code)
            let (pinLat, pinLon): (Double, Double) = {
                if normalized != code.uppercased(),
                   let centroid = GeocodingData.countryCentroid(for: normalized) {
                    return (centroid.lat, centroid.lon)
                }
                return (lat, lon)
            }()
            if let existing = best[normalized] {
                if date > existing.date { best[normalized] = (pinLat, pinLon, date) }
            } else {
                best[normalized] = (pinLat, pinLon, date)
            }
        }

        for trip in store.trips where trip.countsAsVisited {
            consider(code: trip.countryCode, lat: trip.latitude, lon: trip.longitude, date: trip.departureDate)
            for dest in trip.additionalDestinations {
                consider(code: dest.countryCode, lat: dest.latitude, lon: dest.longitude, date: trip.departureDate)
            }
        }

        return best.map { code, info in
            let name = Locale.current.localizedString(forRegionCode: code) ?? code
            return VisitedCountry(countryCode: code, name: name, coordinate: CLLocationCoordinate2D(latitude: info.lat, longitude: info.lon))
        }
    }
}

#endif
