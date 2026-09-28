import ImageIO
import Photos
import UIKit

enum PhotoLibraryError: Error {
    case encodingFailed
    case authorizationDenied
}

enum PhotoLibraryStore {
    static func save(_ image: UIImage) async throws {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        let granted: Bool
        if status == .notDetermined {
            granted = await PHPhotoLibrary.requestAuthorization(for: .addOnly) == .authorized
        } else {
            granted = status == .authorized || status == .limited
        }
        guard granted else { throw PhotoLibraryError.authorizationDenied }

        guard let data = image.heicData() ?? image.jpegData(compressionQuality: 0.92) else {
            throw PhotoLibraryError.encodingFailed
        }

        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, data: data, options: nil)
        }
    }
}

private extension UIImage {
    func heicData() -> Data? {
        guard let cgImage else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.heic" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, cgImage, [
            kCGImageDestinationLossyCompressionQuality: 0.92
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
