//
//  GlobeView.swift
//  Carry

import SwiftUI
import MapKit

// MARK: - Data

struct VisitedCountry: Identifiable {
    var id: String { countryCode }
    let countryCode: String
    let name: String
    let coordinate: CLLocationCoordinate2D
}

// MARK: - GlobeMapView

struct GlobeMapView: View {

    let visitedCountries: [VisitedCountry]

    @State private var position: MapCameraPosition = .camera(
        MapCamera(
            centerCoordinate: CLLocationCoordinate2D(latitude: 25, longitude: 100),
            distance: 30_000_000,
            heading: 0,
            pitch: 0
        )
    )
    @State private var locationManager = CLLocationManager()

    var body: some View {
        Map(position: $position) {
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
            ForEach(visitedCountries) { country in
                Annotation("", coordinate: country.coordinate, anchor: .center) {
                    countryPin(country: country)
                }
            }
        }
        .mapStyle(.hybrid(elevation: .realistic))
        .onAppear {
            locationManager.requestWhenInUseAuthorization()
            locationManager.startUpdatingLocation()
            if let centroid = centroid(of: visitedCountries) {
                position = .camera(MapCamera(
                    centerCoordinate: centroid,
                    distance: 30_000_000
                ))
            }
        }
    }

    // MARK: - Pin

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
