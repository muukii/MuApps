//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import Foundation
import Photos

/// Saves an exported video file into the user's photo library.
///
/// Photos executes its authorization and change callbacks on framework-owned
/// queues. This utility owns no UI state, so keeping it nonisolated prevents
/// those escaping closures from inheriting the app target's default MainActor
/// isolation and trapping when Photos invokes them off the main queue.
nonisolated enum PhotoLibrarySaver {

  enum SaveError: LocalizedError {
    case notAuthorized
    var errorDescription: String? {
      "Färg isn't allowed to add videos to your photo library."
    }
  }

  static func save(videoAt url: URL) async throws {
    let status = await requestAddAuthorization()
    guard status == .authorized || status == .limited else {
      throw SaveError.notAuthorized
    }
    try await PHPhotoLibrary.shared().performChanges {
      let request = PHAssetCreationRequest.forAsset()
      request.addResource(with: .video, fileURL: url, options: nil)
    }
  }

  private static func requestAddAuthorization() async -> PHAuthorizationStatus {
    await withCheckedContinuation { continuation in
      PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
        continuation.resume(returning: status)
      }
    }
  }
}
