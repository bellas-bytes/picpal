import SwiftUI
import PhotosUI

// MARK: - ReferencePhotoPicker

/// A SwiftUI view wrapping `PHPickerViewController` for selecting a single reference photo.
///
/// Uses the modern `PHPickerViewController` API (iOS 14+) rather than the deprecated
/// `UIImagePickerController`. The picker presents in a sheet; the caller controls
/// presentation via a `Bool` binding or `isPresented` modifier.
///
/// No photo library access permission is required — `PHPickerViewController` returns a
/// copy of the selected asset without granting general library access.
///
/// ## Usage
///
/// ```swift
/// .sheet(isPresented: $showReferencePicker) {
///     ReferencePhotoPicker { image in
///         // image is nil when the user cancels
///     }
/// }
/// ```
struct ReferencePhotoPicker: UIViewControllerRepresentable {

    // MARK: - Properties

    /// Called on the main actor when the user selects a photo or cancels the picker.
    /// - Parameter image: The selected `UIImage`, or `nil` if the picker was cancelled.
    let onPick: @MainActor (UIImage?) -> Void

    // MARK: - UIViewControllerRepresentable

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration()
        configuration.selectionLimit = 1
        configuration.filter = .images
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {
        // No dynamic updates required.
    }
}

// MARK: - Coordinator

extension ReferencePhotoPicker {

    /// Bridges `PHPickerViewControllerDelegate` callbacks to the SwiftUI `onPick` closure.
    @MainActor
    final class Coordinator: NSObject, PHPickerViewControllerDelegate {

        private let onPick: @MainActor (UIImage?) -> Void

        init(onPick: @escaping @MainActor (UIImage?) -> Void) {
            self.onPick = onPick
        }

        // MARK: - PHPickerViewControllerDelegate

        nonisolated func picker(
            _ picker: PHPickerViewController,
            didFinishPicking results: [PHPickerResult]
        ) {
            // Dismiss the picker first, before loading the asset.
            Task { @MainActor in
                picker.dismiss(animated: true)
            }

            guard let result = results.first else {
                // User cancelled — report nil.
                Task { @MainActor [self] in
                    self.onPick(nil)
                }
                return
            }

            // Load the image data off the main thread; dispatch back to main to call onPick.
            let provider = result.itemProvider
            provider.loadObject(ofClass: UIImage.self) { object, _ in
                let image = object as? UIImage
                Task { @MainActor [self] in
                    self.onPick(image)
                }
            }
        }
    }
}
