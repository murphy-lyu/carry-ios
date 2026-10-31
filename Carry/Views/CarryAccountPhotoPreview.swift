import SwiftUI
import ImageIO

nonisolated enum CarryAccountPhotoPixels {
    static func image(at url: URL, maxPixel: Int) throws -> UIImage {
        guard (1...4096).contains(maxPixel), url.isFileURL else { throw CarryAccountAssetCacheFailure.invalidSource }
        let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard info.isRegularFile == true, info.isSymbolicLink != true, let count = info.fileSize,
              count > 0, count <= CarryAccountAssetCache.maximumBytes else { throw CarryAccountAssetCacheFailure.invalidSource }
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let pixels = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel
              ] as CFDictionary) else { throw CarryAccountAssetCacheFailure.invalidSource }
        try Task.checkCancellation()
        return UIImage(cgImage: pixels)
    }
}

/// A fullscreen display uses bounded original pixels, not the list thumbnail or
/// an unrestricted 100MP decode. Reading never asks for new Photos permissions.
struct CarryAccountPhotoPreview: View {
    let thumbnail: Data
    let originalToken: String
    let dismiss: () -> Void
    @State private var image: UIImage?
    @State private var unavailable = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let image { Image(uiImage: image).resizable().scaledToFit() }
            VStack {
                HStack {
                    Spacer()
                    Button(action: dismiss) { Image(systemName: "xmark.circle.fill").font(.title).symbolRenderingMode(.palette).foregroundStyle(.white, .black.opacity(0.4)) }
                        .accessibilityLabel(Text("Close"))
                        .frame(minWidth: 44, minHeight: 44)
                }
                Spacer()
                if unavailable { Text("account.photo.original_unavailable").font(.footnote).foregroundStyle(.white).padding().background(.black.opacity(0.6)) }
            }.padding()
        }
        .contentShape(Rectangle()).onTapGesture(perform: dismiss)
        .task(id: originalToken) {
            let preview = thumbnail
            let fallback = Task.detached(priority: .userInitiated) { AttachmentThumbnail.displayImage(from: preview, maxPixel: 2048) }
            image = await fallback.value
            guard !Task.isCancelled else { return }
            let isAccount = CarryAccountFileAccess.isAccountReference(originalToken)
            let isRestoredLocal = originalToken.hasPrefix("carryphoto1_") && !originalToken.contains("/") && !originalToken.contains("\\")
            guard isAccount || isRestoredLocal else { return }
            let resolved = isAccount ? CarryAccountFileAccess.shared.url(named: originalToken) : AttachmentStore.fileURL(named: originalToken)
            guard let url = resolved else { unavailable = true; return }
            let work = Task.detached(priority: .userInitiated) { try CarryAccountPhotoPixels.image(at: url, maxPixel: 3072) }
            do {
                let original = try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
                guard !Task.isCancelled, !isAccount || CarryAccountFileAccess.shared.url(named: originalToken) == url else { return }
                image = original
            } catch is CancellationError { }
            catch { unavailable = true }
        }
    }
}
