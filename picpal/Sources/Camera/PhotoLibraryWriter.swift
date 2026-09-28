import Photos

enum PhotoLibraryWriter {
    enum SaveError: LocalizedError {
        case permissionDenied, saveFailed
        var errorDescription: String? {
            switch self {
            case .permissionDenied: "Allow PicPal to add photos in Settings, then retry saving."
            case .saveFailed: "The photo could not be saved. Please try again."
            }
        }
    }

    /// Saves original encoded data including its orientation and camera metadata.
    /// The caller retains the data and can retry if permission or saving fails.
    static func save(_ data: Data) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw SaveError.permissionDenied }
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, data: data, options: nil)
        }
    }
}
