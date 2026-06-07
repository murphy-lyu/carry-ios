//
//  DestinationMapThumbnail.swift
//  Carry
//
//  EXPERIMENTAL (feature/home-ui-redesign branch).
//  Resolves a trip's card/banner background: user-chosen photo first, then a fallback.
//  Two fallback modes (so Dev Options can compare them side-by-side):
//    .monogram → cohesive "ink" tile + city initial, à la Contacts/Mail avatars (attribution-free)
//    .map      → MKMapSnapshotter mutedStandard tile (with place labels) of the destination
//  NOTE on .map: Apple Maps snapshots carry a non-removable "Maps" attribution (legal +
//  visually heavy) — that's why the default is .monogram. .map is for the 4·Map comparison
//  style only; if chosen for ship, attribution must be handled.
//  NOTE: filename kept for now to avoid a pbxproj rename mid-branch; rename to
//  TripBackgroundView.swift when finalising.
//

import SwiftUI
import UIKit
import MapKit

/// What to show when a trip has no user photo.
enum TripBackgroundFallback {
    case monogram   // ink tile + city initial (default, attribution-free)
    case map        // mutedStandard map snapshot (with place labels) of the destination
}

/// Fills its frame with the trip's background: the user's photo if set, else the chosen
/// fallback. Callers set the frame (banner vs thumb).
struct TripBackgroundView: View {

    @Environment(\.colorScheme) private var colorScheme
    let bundle: TripBundle
    var fallback: TripBackgroundFallback = .monogram

    private var hasCoordinate: Bool { bundle.latitude != 0 || bundle.longitude != 0 }

    private var userEntry: TripBackgroundEntry? {
        guard let entry = bundle.primaryBackground, entry.localFileName != nil else { return nil }
        return entry
    }
    private var userImage: UIImage? {
        guard let name = userEntry?.localFileName else { return nil }
        return BackgroundImageStore.image(named: name)
    }

    /// First character of the destination (then name) — the monogram for photo-less trips,
    /// à la Contacts/Mail avatars. Identity comes from the letter, not from colour.
    private var monogram: String {
        let source = bundle.destinationCity.trimmingCharacters(in: .whitespaces).isEmpty
            ? bundle.name.trimmingCharacters(in: .whitespaces)
            : bundle.destinationCity.trimmingCharacters(in: .whitespaces)
        return String(source.prefix(1)).uppercased()
    }

    var body: some View {
        if let userImage {
            PositionedImage(image: userImage, crop: userEntry?.crop)
        } else if fallback == .map, hasCoordinate {
            DestinationMapTile(
                coordinate: CLLocationCoordinate2D(latitude: bundle.latitude, longitude: bundle.longitude),
                dark: colorScheme == .dark
            )
        } else {
            // No photo → one cohesive, restrained "ink" surface (same for every photo-less
            // trip, so it reads as designed, not a random swatch) + a large soft monogram.
            // White text/chips stay legible; works at both banner and thumbnail sizes.
            GeometryReader { geo in
                let side = min(geo.size.width, geo.size.height)
                ZStack {
                    LinearGradient(
                        colors: colorScheme == .dark
                            ? [Color(red: 0.18, green: 0.20, blue: 0.23), Color(red: 0.10, green: 0.11, blue: 0.13)]
                            : [Color(red: 0.29, green: 0.32, blue: 0.37), Color(red: 0.18, green: 0.20, blue: 0.24)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    Text(monogram)
                        .font(.system(size: side * 0.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.18))
                        .lineLimit(1)
                        .minimumScaleFactor(0.4)
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
    }
}

// MARK: - Map fallback tile (experimental, 4·Map style only)

/// MKMapSnapshotter image of the destination, sized to its frame and cached. Whatever legal
/// attribution MapKit bakes into the snapshot is shown as-is (we do NOT add or fake an Apple
/// logo — trademark-forbidden — and do NOT crop the bottom strip).
private struct DestinationMapTile: View {

    let coordinate: CLLocationCoordinate2D
    let dark: Bool

    @State private var image: UIImage?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottomLeading) {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color(UIColor.secondarySystemBackground)
                }

                // Small "􀣺 Maps" badge (Luggy-style) — the snapshot carries no attribution,
                // so we mark it as Apple Maps. Kept compact so it doesn't swamp the tile.
                if image != nil {
                    HStack(spacing: 1.5) {
                        Image(systemName: "applelogo")
                            .font(.system(size: 7, weight: .medium))
                        Text("Maps")
                            .font(.system(size: 7.5, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.45), radius: 1, y: 0.5)
                    .padding(.leading, 5)
                    .padding(.bottom, 4)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .task(id: "\(geo.size.width)x\(geo.size.height)-\(dark)") {
                image = await DestinationMapSnapshotCache.snapshot(
                    coordinate: coordinate, size: geo.size, dark: dark
                )
            }
        }
    }
}

private enum DestinationMapSnapshotCache {

    private static let cache = NSCache<NSString, UIImage>()

    static func snapshot(coordinate: CLLocationCoordinate2D, size: CGSize, dark: Bool) async -> UIImage? {
        guard size.width > 1, size.height > 1 else { return nil }
        let key = "\(coordinate.latitude),\(coordinate.longitude)-\(Int(size.width))x\(Int(size.height))-\(dark)" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(
            center: coordinate,
            latitudinalMeters: 36_000,
            longitudinalMeters: 36_000
        )
        options.size = size
        options.mapType = .mutedStandard
        options.traitCollection = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)

        let snapshotter = MKMapSnapshotter(options: options)
        let image: UIImage? = await withCheckedContinuation { continuation in
            snapshotter.start(with: .global(qos: .userInitiated)) { snapshot, _ in
                continuation.resume(returning: snapshot?.image)
            }
        }
        if let image { cache.setObject(image, forKey: key) }
        return image
    }
}
