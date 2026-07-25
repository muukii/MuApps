//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

@preconcurrency import AVFoundation
import Photos
import PhotosUI
import SwiftUI

/// The visible state of resolving ordered Photos and Files selections.
nonisolated struct VideoLoadingProgress: Equatable, Sendable {
  let currentItemIndex: Int
  let itemCount: Int

  /// Derives collection progress from the lifecycle owned by each clip.
  @MainActor
  init?(clips: [VideoClip]) {
    guard clips.isEmpty == false else { return nil }
    self.currentItemIndex =
      clips.firstIndex(where: \.isPreparing)
      ?? (clips.count - 1)
    self.itemCount = clips.count
  }
}

/// The successfully opened clips and unavailable picker items.
struct VideoPickerImportResult {

  let clips: [VideoClip]
  let failedCount: Int
  let firstFailureMessage: String?

  /// A localized partial- or total-failure summary suitable for an alert.
  var failureMessage: String? {
    guard failedCount > 0 else { return nil }
    if clips.isEmpty, let firstFailureMessage {
      return firstFailureMessage
    }
    if failedCount == 1 {
      return String(localized: "1 video couldn't be loaded.")
    }
    return String(
      localized: "\(failedCount) videos couldn't be loaded.",
      comment: "The variable is the number of videos that failed to import."
    )
  }
}

/// Opens Photos and Files movies without creating app-owned source copies.
///
/// Photos resolves picker identifiers through PhotoKit into `AVAsset` objects.
/// Files retains each security-scoped URL while AVFoundation reads it in place.
/// Resolution remains serial so multiple iCloud or external-volume movies do
/// not create concurrent download, metadata, and color-inspection work.
nonisolated enum VideoPickerImport {

  /// Creates stable clip identities before source resolution begins.
  @MainActor
  static func makeClips(
    photoItems: [PhotosPickerItem] = [],
    fileURLs: [URL] = []
  ) -> [VideoClip] {
    let selections =
      photoItems.map(VideoSelection.photo)
      + fileURLs.map(VideoSelection.file)

    return selections.map { selection in
      let selectionID = UUID()
      let logContext: VideoImportLogContext = {
        switch selection {
        case .photo:
          return .photos(selectionID: selectionID)
        case .file(let url):
          return .files(selectionID: selectionID, url: url)
        }
      }()
      VideoImportDiagnostics.selectionQueued(logContext)

      return VideoClip(id: selectionID) {
        do {
          let (source, displayName) = try await open(
            selection,
            logContext: logContext
          )
          let videoTrackCount = try await validateVideoAsset(
            source.asset,
            logContext: logContext
          )
          let colorInfo = await VideoColorInfo.resolve(from: source.asset)
          try Task.checkCancellation()
          VideoImportDiagnostics.sourcePrepared(
            logContext,
            videoTrackCount: videoTrackCount
          )

          return VideoClip.Content(
            source: source,
            displayName: displayName,
            colorInfo: colorInfo
          )
        } catch is CancellationError {
          VideoImportDiagnostics.sourcePreparationCancelled(logContext)
          throw CancellationError()
        } catch {
          VideoImportDiagnostics.log(
            error: error,
            stage: "prepareSource",
            context: logContext
          )
          throw error
        }
      }
    }
  }

  @MainActor
  static func load(
    _ clips: [VideoClip],
    requiresPhotoLibraryReadAccess: Bool
  ) async throws -> VideoPickerImportResult {
    if requiresPhotoLibraryReadAccess {
      try await ensurePhotoLibraryReadAccess()
    }

    var failedCount = 0
    var firstFailureMessage: String?

    for clip in clips {
      try Task.checkCancellation()

      do {
        try await clip.load()
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        failedCount += 1
        if firstFailureMessage == nil {
          firstFailureMessage = clip.failureMessage
        }
      }
    }

    return VideoPickerImportResult(
      clips: clips.filter(\.isReady),
      failedCount: failedCount,
      firstFailureMessage: firstFailureMessage
    )
  }

  private static func open(
    _ selection: VideoSelection,
    logContext: VideoImportLogContext
  ) async throws -> (source: VideoSource, displayName: String) {
    switch selection {
    case .photo(let item):
      guard let localIdentifier = item.itemIdentifier else {
        throw VideoImportError.photoIdentifierUnavailable
      }
      let fetchResult = PHAsset.fetchAssets(
        withLocalIdentifiers: [localIdentifier],
        options: nil
      )
      guard let photoAsset = fetchResult.firstObject else {
        throw VideoImportError.photoAssetUnavailable
      }

      let asset = try await PhotoKitVideoAssetRequest.load(photoAsset)
      let source = VideoSource(
        photoLibraryAsset: asset,
        localIdentifier: localIdentifier
      )
      return (
        source,
        photoDisplayName(photoAsset)
      )

    case .file(let url):
      return (
        try VideoSource(
          securityScopedURL: url,
          logContext: logContext
        ),
        url.deletingPathExtension().lastPathComponent
      )
    }
  }

  /// PhotoKit access is required because the privacy picker alone only grants
  /// transferable representations, which can require a full temporary copy.
  private static func ensurePhotoLibraryReadAccess() async throws {
    switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
    case .authorized, .limited:
      return
    case .notDetermined:
      let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
      guard status == .authorized || status == .limited else {
        throw VideoImportError.photoLibraryReadAccessDenied
      }
    case .denied, .restricted:
      throw VideoImportError.photoLibraryReadAccessDenied
    @unknown default:
      throw VideoImportError.photoLibraryReadAccessDenied
    }
  }

  private static func validateVideoAsset(
    _ asset: AVAsset,
    logContext: VideoImportLogContext
  ) async throws -> Int {
    VideoImportDiagnostics.assetValidationStarted(logContext)

    async let isPlayable: Bool = {
      do {
        return try await asset.load(.isPlayable)
      } catch {
        VideoImportDiagnostics.log(
          error: error,
          stage: "loadIsPlayable",
          context: logContext
        )
        throw error
      }
    }()
    async let videoTracks: [AVAssetTrack] = {
      do {
        return try await asset.loadTracks(withMediaType: .video)
      } catch {
        VideoImportDiagnostics.log(
          error: error,
          stage: "loadVideoTracks",
          context: logContext
        )
        throw error
      }
    }()

    let validation = try await (isPlayable, videoTracks)
    guard validation.0, validation.1.isEmpty == false else {
      VideoImportDiagnostics.assetValidationRejected(
        logContext,
        isPlayable: validation.0,
        videoTrackCount: validation.1.count
      )
      throw VideoImportError.unsupportedVideo
    }
    return validation.1.count
  }

  private static func photoDisplayName(_ asset: PHAsset) -> String {
    let resource = PHAssetResource.assetResources(for: asset).first {
      $0.type == .video || $0.type == .fullSizeVideo
    }
    guard let resource else {
      return String(localized: "Photos Video")
    }
    return URL(fileURLWithPath: resource.originalFilename)
      .deletingPathExtension()
      .lastPathComponent
  }
}

/// One ordered source selection waiting to be resolved into a clip.
private nonisolated enum VideoSelection: Sendable {
  case photo(PhotosPickerItem)
  case file(URL)
}

/// Requests a PhotoKit-backed `AVAsset` and propagates task cancellation.
private nonisolated enum PhotoKitVideoAssetRequest {

  static func load(_ photoAsset: PHAsset) async throws -> AVAsset {
    let options = PHVideoRequestOptions()
    options.deliveryMode = .highQualityFormat
    options.version = .current
    options.isNetworkAccessAllowed = true

    let requestHandle = PhotoKitRequestHandle()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<AVAsset, any Error>) in
        let requestID = PHImageManager.default().requestAVAsset(
          forVideo: photoAsset,
          options: options
        ) { asset, _, info in
          if let asset {
            continuation.resume(returning: asset)
          } else if (info?[PHImageCancelledKey] as? NSNumber)?.boolValue == true {
            continuation.resume(throwing: CancellationError())
          } else if let error = info?[PHImageErrorKey] as? any Error {
            continuation.resume(throwing: error)
          } else {
            continuation.resume(throwing: VideoImportError.photoAssetUnavailable)
          }
        }
        requestHandle.register(requestID)
      }
    } onCancel: {
      requestHandle.cancel()
    }
  }
}

/// Bridges cancellation that can race PhotoKit returning its request identifier.
private nonisolated final class PhotoKitRequestHandle: @unchecked Sendable {
  private let lock = NSLock()
  private var requestID: PHImageRequestID?
  private var isCancelled = false

  func register(_ requestID: PHImageRequestID) {
    lock.lock()
    if isCancelled {
      lock.unlock()
      PHImageManager.default().cancelImageRequest(requestID)
    } else {
      self.requestID = requestID
      lock.unlock()
    }
  }

  func cancel() {
    lock.lock()
    isCancelled = true
    let requestID = requestID
    lock.unlock()

    if let requestID {
      PHImageManager.default().cancelImageRequest(requestID)
    }
  }
}

/// Failures that prevent a selected source from becoming an editable movie.
private nonisolated enum VideoImportError: LocalizedError, Sendable {
  case photoLibraryReadAccessDenied
  case photoIdentifierUnavailable
  case photoAssetUnavailable
  case unsupportedVideo

  var errorDescription: String? {
    switch self {
    case .photoLibraryReadAccessDenied:
      return "Allow Färg to read the selected videos in Photos Settings."
    case .photoIdentifierUnavailable:
      return "Färg couldn't identify that Photos video without copying it."
    case .photoAssetUnavailable:
      return "That Photos video isn't available to Färg."
    case .unsupportedVideo:
      return "The selected file doesn't contain a playable video track."
    }
  }
}
