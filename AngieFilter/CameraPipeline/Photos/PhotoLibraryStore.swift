import ImageIO
import Photos
import UIKit

enum PhotoLibraryError: Error {
    case encodingFailed
    case authorizationDenied
}

/// A finished Live Photo in the temporary directory: the graded still and its graded movie, sharing one content identifier.
struct LivePhotoFiles: Equatable, Sendable {
    let photo: URL
    let movie: URL

    func discard() {
        try? FileManager.default.removeItem(at: photo)
        try? FileManager.default.removeItem(at: movie)
    }
}

enum PhotoLibraryStore {
    static func save(_ image: UIImage) async throws {
        try await requestAccess()
        guard let data = image.heicData() ?? image.jpegData(compressionQuality: 0.92) else {
            throw PhotoLibraryError.encodingFailed
        }

        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, data: data, options: nil)
        }
    }

    static func saveLive(_ files: LivePhotoFiles) async throws {
        try await requestAccess()
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, fileURL: files.photo, options: nil)
            request.addResource(with: .pairedVideo, fileURL: files.movie, options: nil)
        }
    }

    static func saveVideo(_ url: URL) async throws {
        try await requestAccess()
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .video, fileURL: url, options: nil)
        }
    }

    /// Photos pairs a still with its movie through Apple maker note key 17, which must equal the movie's content identifier.
    static func writeLiveStill(_ image: UIImage, identifier: String, to url: URL) throws {
        guard let cgImage = image.cgImage,
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.heic" as CFString, 1, nil) else {
            throw PhotoLibraryError.encodingFailed
        }
        CGImageDestinationAddImage(destination, cgImage, [
            kCGImageDestinationLossyCompressionQuality: 0.92,
            kCGImagePropertyMakerAppleDictionary: ["17": identifier]
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw PhotoLibraryError.encodingFailed }
    }

    private static func requestAccess() async throws {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        let granted: Bool
        if status == .notDetermined {
            granted = await PHPhotoLibrary.requestAuthorization(for: .addOnly) == .authorized
        } else {
            granted = status == .authorized || status == .limited
        }
        guard granted else { throw PhotoLibraryError.authorizationDenied }
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
