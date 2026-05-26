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
    @Environment(\.colorScheme) private var colorScheme

    static func == (lhs: GlobeMapView, rhs: GlobeMapView) -> Bool {
        lhs.cityOpacity == rhs.cityOpacity
            && lhs.mapStyleOption == rhs.mapStyleOption
            && lhs.showUserLocation == rhs.showUserLocation
            && lhs.introSpinTrigger == rhs.introSpinTrigger
            && lhs.visitedCities.count == rhs.visitedCities.count
            && lhs.visitedCountries.count == rhs.visitedCountries.count
            && zip(lhs.visitedCities, rhs.visitedCities).allSatisfy { $0.id == $1.id }
            && zip(lhs.visitedCountries, rhs.visitedCountries).allSatisfy { $0.countryCode == $1.countryCode }
    }

    /// Incremented once per session on the first sheet collapse to trigger the intro spin.
    var introSpinTrigger: Int = 0

    @State private var position: MapCameraPosition = .automatic
    @State private var cityDotsAppeared: Bool = false
    @State private var userPulseAnimating: Bool = false
    @State private var userPulseAnimating2: Bool = false

    var body: some View {
        Map(position: $position) {
            // City dots — subtle, fade in as sheet collapses
            ForEach(visitedCities) { city in
                Annotation("", coordinate: city.coordinate, anchor: .center) {
                    cityDot
                        .scaleEffect(cityDotsAppeared ? 1.0 : 0.95)
                        .opacity(cityDotsAppeared ? cityOpacity : 0)
                }
            }
            // Country pins — always visible
            ForEach(visitedCountries) { country in
                Annotation("", coordinate: country.coordinate, anchor: .center) {
                    countryPin(country: country)
                }
            }
            // Only rendered after the user explicitly enables location.
            // Declared last so it stays visually above other map annotations.
            if showUserLocation {
                UserAnnotation {
                    userLocationDot
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
            guard !cityDotsAppeared else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                cityDotsAppeared = true
            }
        }
        .onChange(of: showUserLocation) { _, newValue in
            if !newValue {
                userPulseAnimating = false
                userPulseAnimating2 = false
            }
        }
        .onChange(of: introSpinTrigger) { _, new in
            guard new > 0 else { return }
            // Use the current live camera position; fall back to a reasonable default.
            let fallback = MapCamera(
                centerCoordinate: CLLocationCoordinate2D(latitude: 25, longitude: 100),
                distance: 30_000_000
            )
            let cam = position.camera ?? fallback
            // Rotate the globe by 30° — feels alive without being distracting.
            // Tunable parameters:
            //   • heading offset: how far it rotates (larger = more dramatic)
            //   • duration: speed of the spin (longer = more cinematic)
            //   • delay: pause before spin starts (lets the sheet settle first)
            let rotated = MapCamera(
                centerCoordinate: cam.centerCoordinate,
                distance: cam.distance,
                heading: cam.heading + 30,
                pitch: cam.pitch
            )
            withAnimation(.easeInOut(duration: 2.0).delay(0.15)) {
                position = .camera(rotated)
            }
        }
    }

    // MARK: - City dot

    private var userLocationDot: some View {
        ZStack {
            Circle()
                .stroke(Color.orange.opacity(0.35), lineWidth: 2)
                .frame(width: 18, height: 18)
                .scaleEffect(userPulseAnimating ? 1.75 : 1.0)
                .opacity(userPulseAnimating ? 0 : 0.75)
                .animation(
                    .linear(duration: 2.1).repeatForever(autoreverses: false),
                    value: userPulseAnimating
                )
            Circle()
                .stroke(Color.orange.opacity(0.24), lineWidth: 1.6)
                .frame(width: 18, height: 18)
                .scaleEffect(userPulseAnimating2 ? 1.75 : 1.0)
                .opacity(userPulseAnimating2 ? 0 : 0.56)
                .animation(
                    .linear(duration: 2.1).repeatForever(autoreverses: false).delay(1.05),
                    value: userPulseAnimating2
                )

            Circle()
                .fill(.orange)
                .frame(width: 16, height: 16)
            Circle()
                .fill(.white)
                .frame(width: 6, height: 6)
        }
        .onAppear {
            guard !userPulseAnimating else { return }
            userPulseAnimating = true
            userPulseAnimating2 = true
        }
    }

    private var cityDot: some View {
        ZStack {
            // Outer soft ring
            Circle()
                .fill(Color(red: 0.44, green: 0.83, blue: 1.0).opacity(0.20))
                .frame(width: 18, height: 18)
            // Core dot
            Circle()
                .fill(Color(red: 0.41, green: 0.81, blue: 1.0))
                .frame(width: 8, height: 8)
                .overlay {
                    Circle()
                        .stroke(
                            colorScheme == .dark
                                ? Color.white.opacity(0.34)
                                : Color.black.opacity(0.14),
                            lineWidth: 1
                        )
                }
        }
        .shadow(
            color: colorScheme == .dark
                ? Color.black.opacity(0.35)
                : Color.black.opacity(0.16),
            radius: 2,
            x: 0,
            y: 1
        )
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
