//
//  BackgroundPicker.swift
//  Carry
//
//  PHPicker wrapper for choosing a trip background from the photo library.
//  No photo-library permission prompt needed (PHPicker runs out-of-process).
//  Reports the picked item provider (loading — incl. iCloud download — is handled by the
//  caller so it can show progress); reports cancellation so the host can dismiss.
//

import SwiftUI
import PhotosUI
import UIKit

/// Pick a single image from the photo library. Callbacks fire on the main thread.
struct PhotoPicker: UIViewControllerRepresentable {

    var onPick: (NSItemProvider) -> Void
    var onCancel: () -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        // .compatible transcodes to a widely-loadable format and reliably triggers iCloud
        // download — .current can hand back a representation that fails to load for cloud assets.
        config.preferredAssetRepresentationMode = .compatible
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick, onCancel: onCancel) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPick: (NSItemProvider) -> Void
        let onCancel: () -> Void
        init(onPick: @escaping (NSItemProvider) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            // Do NOT dismiss here — the host swaps the sheet's content (picker → loading →
            // reposition), so dismissing out-of-band would fight SwiftUI's presentation state.
            guard let provider = results.first?.itemProvider else {
                onCancel()
                return
            }
            onPick(provider)
        }
    }
}
