//
//  GlobeView.swift
//  Carry

import SwiftUI
import MapKit
import CoreLocation

// MARK: - Data

struct VisitedCountry: Identifiable {
    var id: String { countryCode }
    let countryCode: String
    let name: String
    let coordinate: CLLocationCoordinate2D
}

struct VisitedCity: Identifiable {
    let id: String          // dedup key based on rounded coordinate
    let coordinate: CLLocationCoordinate2D
}

// MARK: - Map style

enum MapStyleOption: String, CaseIterable {
    case hybrid   = "hybrid"
    case standard = "standard"

    var mapStyle: MapStyle {
        switch self {
        case .hybrid:   return .hybrid(elevation: .realistic)
        case .standard: return .standard(elevation: .realistic)
        }
    }

    var label: LocalizedStringKey {
        switch self {
        case .hybrid:   return "map.style.hybrid"
        case .standard: return "map.style.standard"
        }
    }

    var icon: String {
        switch self {
        case .hybrid:   return "map.fill"
        case .standard: return "road.lanes"
        }
    }
}

// MARK: - Location permission manager

/// Handles CLLocationManager lifecycle and authorization state.
/// Owned by HomeView so the permission button and the map share the same state.
@Observable
final class LocationPermissionManager: NSObject, CLLocationManagerDelegate {

    private(set) var authStatus: CLAuthorizationStatus = .notDetermined
    private(set) var isTracking = false

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        authStatus = manager.authorizationStatus
    }

    /// Call when the user taps the location button.
    func handleTap() {
        switch authStatus {
        case .notDetermined:
            // Triggers the system dialog; delegate callback will enable tracking
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            isTracking.toggle()
            if isTracking {
                manager.startUpdatingLocation()
            } else {
                manager.stopUpdatingLocation()
            }
        case .denied, .restricted:
            // Guide the user to Settings to change the decision
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        @unknown default:
            break
        }
    }

    // MARK: CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authStatus = manager.authorizationStatus
        // Automatically start tracking once the user grants permission
        if authStatus == .authorizedWhenInUse || authStatus == .authorizedAlways {
            isTracking = true
            manager.startUpdatingLocation()
        } else {
            isTracking = false
            manager.stopUpdatingLocation()
        }
    }
}

// MARK: - GlobeMapView

/// Custom equality: skip body re-evaluation when all inputs are stable.
/// During the sheet snap spring animation, HomeView.body re-evaluates every frame
/// (sheetOffset is @State). Without Equatable, SwiftUI always calls GlobeMapView.body
/// → MapKit updates all Annotation views every frame → jank at spring tail.
/// With Equatable + .equatable() modifier, SwiftUI compares old vs new struct;
/// if equal (trips didn't change, cityOpacity stable), body is skipped entirely.
struct GlobeMapView: View, Equatable {

    let visitedCountries: [VisitedCountry]
    let visitedCities: [VisitedCity]
    /// 0 = fully expanded (cities hidden), 1 = fully collapsed (cities visible)
    var cityOpacity: Double
    var mapStyleOption: MapStyleOption = .hybrid
    /// Controlled by the parent; true only after the user grants location permission.
    var showUserLocation: Bool = false

    static func == (lhs: GlobeMapView, rhs: GlobeMapView) -> Bool {
        lhs.cityOpacity == rhs.cityOpacity
            && lhs.mapStyleOption == rhs.mapStyleOption
            && lhs.showUserLocation == rhs.showUserLocation
            && lhs.visitedCities.count == rhs.visitedCities.count
            && lhs.visitedCountries.count == rhs.visitedCountries.count
            && zip(lhs.visitedCities, rhs.visitedCities).allSatisfy { $0.id == $1.id }
            && zip(lhs.visitedCountries, rhs.visitedCountries).allSatisfy { $0.countryCode == $1.countryCode }
    }

    @State private var position: MapCameraPosition = .camera(
        MapCamera(
            centerCoordinate: CLLocationCoordinate2D(latitude: 25, longitude: 100),
            distance: 30_000_000,
            heading: 0,
            pitch: 0
        )
    )

    var body: some View {
        Map(position: $position) {
            // Only rendered after the user explicitly enables location
            if showUserLocation {
                UserAnnotation {
                    ZStack {
                        Circle()
                            .fill(.orange.opacity(0.25))
                            .frame(width: 36, height: 36)
                        Circle()
                            .fill(.orange)
                            .frame(width: 20, height: 20)
                        Circle()
                            .fill(.white)
                            .frame(width: 8, height: 8)
                    }
                }
            }
            // City dots — subtle, fade in as sheet collapses
            ForEach(visitedCities) { city in
                Annotation("", coordinate: city.coordinate, anchor: .center) {
                    cityDot
                        .opacity(cityOpacity)
                }
            }
            // Country pins — always visible
            ForEach(visitedCountries) { country in
                Annotation("", coordinate: country.coordinate, anchor: .center) {
                    countryPin(country: country)
                }
            }
        }
        .mapStyle(mapStyleOption.mapStyle)
        .onAppear {
            if let centroid = centroid(of: visitedCountries) {
                position = .camera(MapCamera(
                    centerCoordinate: centroid,
                    distance: 30_000_000
                ))
            }
        }
    }

    // MARK: - City dot

    private var cityDot: some View {
        ZStack {
            // Outer glow ring
            Circle()
                .fill(.white.opacity(0.22))
                .frame(width: 20, height: 20)
            // Solid center
            Circle()
                .fill(.white.opacity(0.90))
                .frame(width: 11, height: 11)
            // Inner white highlight
            Circle()
                .fill(.white)
                .frame(width: 5, height: 5)
        }
        .shadow(color: .black.opacity(0.25), radius: 3, x: 0, y: 1)
    }

    // MARK: - Country pin

    private func countryPin(country: VisitedCountry) -> some View {
        VStack(spacing: 5) {
            flagCircle(for: country.countryCode)
                .shadow(color: .black.opacity(0.4), radius: 6, x: 0, y: 3)
            Text(country.name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(Color.black.opacity(0.52))
                )
        }
    }

    private func flagCircle(for code: String) -> some View {
        Text(flagEmoji(for: code))
            .font(.system(size: 52))
            .frame(width: 44, height: 44)
            .clipShape(Circle())
    }

    // MARK: - Helpers

    private func flagEmoji(for code: String) -> String {
        guard code.count == 2 else { return "📍" }
        let base: UInt32 = 0x1F1E6 - 65
        return code.uppercased().unicodeScalars.compactMap {
            UnicodeScalar(base + $0.value)
        }.map(String.init).joined()
    }

    private func centroid(of countries: [VisitedCountry]) -> CLLocationCoordinate2D? {
        guard !countries.isEmpty else { return nil }
        let lat = countries.map(\.coordinate.latitude).reduce(0, +) / Double(countries.count)
        let lon = countries.map(\.coordinate.longitude).reduce(0, +) / Double(countries.count)
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}
