//
//  BackgroundReposition.swift
//  Carry
//
//  Lets the user choose which region of a picked photo shows on the wide background card —
//  pan + pinch over a card-aspect window, non-destructive (stores a normalized crop, original
//  image untouched). iOS has no built-in arbitrary-aspect crop component, so this wraps a
//  UIScrollView (which gives robust pan/zoom/clamping for free) and reads back the visible rect.
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Loads a picked item provider into a UIImage — `loadObject` first, falling back to
/// `loadDataRepresentation` (more reliable for iCloud / HEIC assets, and triggers the download).
/// `completion` always runs on the main thread, with nil on failure.
func loadBackgroundImage(from provider: NSItemProvider, completion: @escaping (UIImage?) -> Void) {
    let finish: (UIImage?) -> Void = { image in
        DispatchQueue.main.async { completion(image) }
    }
    if provider.canLoadObject(ofClass: UIImage.self) {
        provider.loadObject(ofClass: UIImage.self) { object, _ in
            if let image = object as? UIImage { finish(image) }
            else { loadBackgroundData(provider, finish) }
        }
    } else {
        loadBackgroundData(provider, finish)
    }
}

private func loadBackgroundData(_ provider: NSItemProvider, _ finish: @escaping (UIImage?) -> Void) {
    let type = UTType.image.identifier
    guard provider.hasItemConformingToTypeIdentifier(type) else { finish(nil); return }
    provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
        finish(data.flatMap { UIImage(data: $0) })
    }
}

/// Displays a background image honouring the user's chosen `crop` as a FOCAL region, not a
/// hard pre-crop: the crop's centre is kept centred and its size sets the zoom, then the image
/// is clamped to cover the frame. Device/aspect-independent — the framed subject is never cut;
/// a wider frame just reveals a little more around it (vs. scaledToFill of a pre-cropped image,
/// which double-crops and clips the subject).
struct PositionedImage: View {
    let image: UIImage
    let crop: BackgroundCrop?

    var body: some View {
        GeometryReader { geo in
            let W = geo.size.width, H = geo.size.height
            let iw = max(image.size.width, 1), ih = max(image.size.height, 1)
            let c = crop ?? .full
            let cw = max(c.width, 0.01), ch = max(c.height, 0.01)
            // Scale so the chosen region fills the frame (the tighter axis wins).
            let scale = max(W / (cw * iw), H / (ch * ih))
            let dispW = iw * scale, dispH = ih * scale
            let focusX = (c.x + cw / 2) * iw * scale
            let focusY = (c.y + ch / 2) * ih * scale
            let offX = min(0, max(W - dispW, W / 2 - focusX))
            let offY = min(0, max(H - dispH, H / 2 - focusY))
            Image(uiImage: image)
                .resizable()
                .frame(width: dispW, height: dispH)
                .offset(x: offX, y: offY)
                .frame(width: W, height: H, alignment: .topLeading)
                .clipped()
        }
    }
}

struct BackgroundRepositionView: View {

    /// Shared aspect (width / height) for the home photo card AND this reposition window — the
    /// single source of truth that makes preview == display. The card uses it as a MINIMUM
    /// height (grows taller for long text / progress, never wider), so framing is never cut.
    static let displayAspect: CGFloat = 4.0

    let image: UIImage
    let onSave: (BackgroundCrop) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var crop: BackgroundCrop = .full

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                ZoomableImageView(image: image) { crop = $0 }
                    .aspectRatio(Self.displayAspect, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
                    )
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                Text("trip.background.adjust.hint")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                Spacer()
            }
            .padding(.top, 12)
            .navigationTitle("trip.background.adjust.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(crop)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}

/// UIScrollView-backed pan/zoom over an image, reporting the visible region as a normalized
/// `BackgroundCrop`. Min zoom = aspect-fill so the window is always covered.
private struct ZoomableImageView: UIViewRepresentable {

    let image: UIImage
    let onCropChange: (BackgroundCrop) -> Void

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.bouncesZoom = true
        scrollView.clipsToBounds = true
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.backgroundColor = .secondarySystemBackground

        let imageView = UIImageView(image: image)
        imageView.isUserInteractionEnabled = false
        scrollView.addSubview(imageView)

        context.coordinator.scrollView = scrollView
        context.coordinator.imageView = imageView
        return scrollView
    }

    func updateUIView(_ uiView: UIScrollView, context: Context) {
        context.coordinator.configureIfNeeded()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onCropChange: onCropChange) }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var scrollView: UIScrollView?
        weak var imageView: UIImageView?
        private let onCropChange: (BackgroundCrop) -> Void
        private var configured = false

        init(onCropChange: @escaping (BackgroundCrop) -> Void) {
            self.onCropChange = onCropChange
        }

        func configureIfNeeded() {
            guard !configured,
                  let scrollView, let imageView,
                  let img = imageView.image,
                  scrollView.bounds.width > 0, scrollView.bounds.height > 0 else { return }
            configured = true

            let imgSize = img.size
            imageView.frame = CGRect(origin: .zero, size: imgSize)
            scrollView.contentSize = imgSize

            let fillScale = max(scrollView.bounds.width / imgSize.width,
                                scrollView.bounds.height / imgSize.height)
            scrollView.minimumZoomScale = fillScale
            scrollView.maximumZoomScale = fillScale * 4
            scrollView.zoomScale = fillScale

            // Center the (overflowing) content in the window.
            let offX = max(0, (scrollView.contentSize.width - scrollView.bounds.width) / 2)
            let offY = max(0, (scrollView.contentSize.height - scrollView.bounds.height) / 2)
            scrollView.contentOffset = CGPoint(x: offX, y: offY)

            emitCrop()
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
        func scrollViewDidScroll(_ scrollView: UIScrollView) { emitCrop() }
        func scrollViewDidZoom(_ scrollView: UIScrollView) { emitCrop() }

        private func emitCrop() {
            guard configured, let scrollView, let imageView,
                  imageView.bounds.width > 0, imageView.bounds.height > 0 else { return }
            // The window mapped into the imageView's own (unzoomed, image-point) coordinate space.
            let visible = scrollView.convert(scrollView.bounds, to: imageView)
            let w = imageView.bounds.width, h = imageView.bounds.height

            var x = Double(visible.minX / w)
            var y = Double(visible.minY / h)
            var cw = Double(visible.width / w)
            var ch = Double(visible.height / h)
            x = min(max(x, 0), 1); y = min(max(y, 0), 1)
            cw = min(cw, 1 - x); ch = min(ch, 1 - y)

            onCropChange(BackgroundCrop(x: x, y: y, width: cw, height: ch))
        }
    }
}
