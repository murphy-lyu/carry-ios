//
//  TripBackground.swift
//  Carry
//
//  User-chosen trip background image: data model + local (sandbox) storage.
//  Source-agnostic + array-ready so Phase 2 (online image search) and multi-destination
//  backgrounds can be added without a schema or UI rewrite. See specs/trip-background-image.md.
//

import UIKit

/// Non-destructive framing: the visible sub-rect of the stored image, in normalized image
/// coordinates (0…1). Lets the user choose which region of a tall/wide photo shows on the
/// wide background card, without altering the original. Nil → show the whole image.
struct BackgroundCrop: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    static let full = BackgroundCrop(x: 0, y: 0, width: 1, height: 1)
    var isFull: Bool { x <= 0.0005 && y <= 0.0005 && width >= 0.9995 && height >= 0.9995 }
}

/// One background image for a trip. Stored JSON-encoded in `TripBundle.backgroundsData`.
struct TripBackgroundEntry: Codable, Equatable {

    enum Source: String, Codable {
        case local       // user uploaded from Photos (Phase 1)
        case unsplash    // Phase 2
        case pexels      // Phase 2
    }

    var source: Source
    /// Sandbox filename of the (compressed) image. Always present for `local`, and for
    /// online sources once the chosen photo is downloaded locally.
    var localFileName: String?
    /// Which destination this background belongs to (Phase 1 always 0; multi-destination ready).
    var destinationIndex: Int = 0
    /// User-chosen framing (optional → backward compatible; missing decodes to nil = full image).
    var crop: BackgroundCrop?

    // Online-source attribution (Phase 1: nil; Phase 2 fills these — no model change needed).
    var photographerName: String?
    var attributionURL: String?
    var downloadLocationURL: String?
}

/// Compressed background images live in the sandbox (no server). Phase 1 stores local uploads;
/// Phase 2 stores downloaded online photos the same way.
enum BackgroundImageStore {

    /// Long-edge cap + JPEG quality — keeps stored/backup size small (~150–400KB) without
    /// visible loss at card/detail display sizes. NOT a user setting.
    static let maxLongEdge: CGFloat = 1400
    static let jpegQuality: CGFloat = 0.72

    private static let decodedCache = NSCache<NSString, UIImage>()

    private static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("TripBackgrounds", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    static func fileURL(named name: String) -> URL { directory.appendingPathComponent(name) }

    /// Compresses + saves an image; returns the stored filename (or nil on failure).
    static func save(_ image: UIImage) -> String? {
        let resized = downscaled(image, longEdge: maxLongEdge)
        guard let data = resized.jpegData(compressionQuality: jpegQuality) else { return nil }
        let name = UUID().uuidString + ".jpg"
        do {
            try data.write(to: fileURL(named: name), options: .atomic)
            decodedCache.setObject(resized, forKey: name as NSString)
            return name
        } catch {
            CarryLogger.shared.log(.dataCorrupted, context: "bg image save failed")
            return nil
        }
    }

    static func image(named name: String) -> UIImage? {
        if let cached = decodedCache.object(forKey: name as NSString) { return cached }
        guard let img = UIImage(contentsOfFile: fileURL(named: name).path) else { return nil }
        decodedCache.setObject(img, forKey: name as NSString)
        return img
    }

    static func delete(named name: String) {
        decodedCache.removeObject(forKey: name as NSString)
        try? FileManager.default.removeItem(at: fileURL(named: name))
    }

    /// Every image filename currently stored in the sandbox.
    static func allStoredFileNames() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    }

    /// Deletes any stored file NOT in `referenced`. This is the lifecycle backstop: trip
    /// removal happens through several paths (per-trip delete, and full-wipe during restore),
    /// and sandbox files aren't in SwiftData so no cascade frees them. Reconciling against the
    /// set of still-referenced names reclaims orphans regardless of which path removed the trip.
    /// Idempotent and cheap (a directory listing + a few unlinks).
    static func deleteOrphans(keeping referenced: Set<String>) {
        for name in allStoredFileNames() where !referenced.contains(name) {
            delete(named: name)
        }
    }

    /// Raw stored bytes — for backup export.
    static func data(named name: String) -> Data? {
        try? Data(contentsOf: fileURL(named: name))
    }

    /// Write bytes under a name — for backup restore.
    @discardableResult
    static func write(data: Data, named name: String) -> Bool {
        do { try data.write(to: fileURL(named: name), options: .atomic); return true } catch { return false }
    }

    /// Copies a stored image to a NEW filename and returns it — used when duplicating a trip so
    /// the copy owns its own bytes. Never share a filename between trips: the per-trip cleanup
    /// (delete on trip removal / background replacement) would otherwise delete a file still in
    /// use by the other trip. Returns nil on failure (caller then leaves the copy photo-less).
    static func copy(of name: String) -> String? {
        guard let bytes = data(named: name) else { return nil }
        let newName = UUID().uuidString + ".jpg"
        return write(data: bytes, named: newName) ? newName : nil
    }

    /// Always re-renders the image upright at scale 1 (orientation baked in) and downsized to
    /// `longEdge` if larger. Orientation-baking is required so the normalized crop rect maps
    /// straight to `cgImage` pixels (a raw rotated cgImage would crop the wrong region).
    private static func downscaled(_ image: UIImage, longEdge: CGFloat) -> UIImage {
        let maxSide = max(image.size.width, image.size.height)
        let factor = (maxSide > longEdge && maxSide > 0) ? longEdge / maxSide : 1
        let newSize = CGSize(width: (image.size.width * factor).rounded(),
                             height: (image.size.height * factor).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = true
        format.scale = 1
        return UIGraphicsImageRenderer(size: newSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
