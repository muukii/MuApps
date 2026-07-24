//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import AVFoundation
import BrightroomParametric
import CoreImage
import Foundation

/// Errors surfaced while exporting a video.
nonisolated enum VideoExportError: LocalizedError {
  case cannotCreateSession
  case failed(String)

  var errorDescription: String? {
    switch self {
    case .cannotCreateSession:
      return "Could not create the video export session."
    case .failed(let message):
      return message
    }
  }
}

/// Renders a parametric document over a video and writes a new file.
///
/// A protocol so the export strategy can evolve (e.g. an `AVAssetReader` /
/// `AVAssetWriter` pipeline) without touching callers.
nonisolated protocol VideoExporting: Sendable {
  func export(
    asset: AVAsset,
    document: EditingDocument,
    colorInfo: VideoColorInfo,
    to outputURL: URL,
    onProgress: @escaping @Sendable (Double) -> Void
  ) async throws
}

/// Default exporter: `ParametricVideoRenderer` composition driven through an
/// `AVAssetExportSession`. Audio passes through; LUT-only edits preserve extent
/// so the source render size is used. An empty document exports by passthrough
/// (no transcode), and the output color is tagged from the source.
nonisolated struct ParametricVideoExporter: VideoExporting {

  var renderSizeMode: ParametricVideoRenderer.RenderSizeMode = .source
  var presetName: String = AVAssetExportPresetHighestQuality
  var ciContext: CIContext = BrightroomVideoCIContext.shared

  func export(
    asset: AVAsset,
    document: EditingDocument,
    colorInfo: VideoColorInfo,
    to outputURL: URL,
    onProgress: @escaping @Sendable (Double) -> Void
  ) async throws {

    let isPassthrough = document.mainTree.features.contains(where: \.isEnabled) == false
    let preset = isPassthrough ? AVAssetExportPresetPassthrough : presetName

    guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
      throw VideoExportError.cannotCreateSession
    }

    if isPassthrough == false {
      let composition = try ParametricVideoRenderer().makeVideoComposition(
        for: asset,
        document: document,
        renderSizeMode: renderSizeMode,
        ciContext: ciContext
      )
      colorInfo.apply(to: composition)
      session.videoComposition = composition
    }

    try? FileManager.default.removeItem(at: outputURL)

    let sessionHandle = VideoExportSessionHandle(session)
    let progressTask = Task {
      await sessionHandle.observeProgress(onProgress)
    }
    defer { progressTask.cancel() }

    try await withTaskCancellationHandler {
      try await sessionHandle.export(to: outputURL)
    } onCancel: {
      sessionHandle.cancel()
    }

    onProgress(1.0)
  }
}

/// Owns an export session while export and progress observation run concurrently.
///
/// `AVAssetExportSession` predates `Sendable`, while its modern async API is
/// explicitly designed for exporting, observing state, and cancelling from
/// separate tasks. This holder keeps that unchecked boundary local instead of
/// leaking the non-Sendable session into the rest of the app.
private nonisolated final class VideoExportSessionHandle: @unchecked Sendable {
  private let session: AVAssetExportSession

  init(_ session: AVAssetExportSession) {
    self.session = session
  }

  func export(to outputURL: URL) async throws {
    try await session.export(to: outputURL, as: .mov)
  }

  func observeProgress(_ onProgress: @escaping @Sendable (Double) -> Void) async {
    for await state in session.states(updateInterval: 0.2) {
      if case .exporting(let progress) = state {
        onProgress(progress.fractionCompleted)
      }
    }
  }

  func cancel() {
    session.cancelExport()
  }
}
