//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import AVFoundation
import AppIntents
import BrightroomParametric
import FargMotionBlur
import Foundation
import UniformTypeIdentifiers

/// Renders a Shortcuts-supplied movie with a selected LUT and returns the result.
///
/// This iOS 26 implementation runs as a regular background App Intent, so the
/// system may cancel a long render when its background runtime expires. The
/// rendering boundary is intentionally independent of App Intents lifecycle.
/// Builds made with the iOS 27 SDK automatically adopt `LongRunningIntent` and
/// request its extended GPU-capable runtime on iOS 27 or later.
struct ApplyLUTToVideoIntent: ProgressReportingIntent {

  static let title: LocalizedStringResource = "Apply LUT to Video"
  static let description = IntentDescription(
    "Render a video with a Färg LUT and return the finished movie."
  )
  static let supportedModes: IntentModes = .background
  static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

  @Parameter(
    title: "Video",
    description: "The video to render.",
    supportedContentTypes: [.movie],
    inputConnectionBehavior: .connectToPreviousIntentResult
  )
  var video: IntentFile

  @Parameter(
    title: "LUT",
    description: "A LUT from the Färg library.",
    optionsProvider: LUTIntentOptionsProvider()
  )
  var lutID: String

  static var parameterSummary: some ParameterSummary {
    Summary("Apply \(\.$lutID) to \(\.$video)")
  }

  init() {}

  @MainActor
  func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
    let library = LUTLibrary()
    guard let lut = library.lut(id: lutID) else {
      throw ApplyLUTToVideoError.lutUnavailable
    }

    let inputURL: URL
    do {
      inputURL = try await ShortcutVideoFileImporter.copyToAppCache(video)
    } catch {
      throw ApplyLUTToVideoError.videoImportFailed(error.localizedDescription)
    }
    defer { try? FileManager.default.removeItem(at: inputURL) }

    let feature = try library.feature(for: lut, amount: 1)
    let document = EditingDocument(
      mainTree: MainTree(features: [.effect(feature)])
    )
    let asset = AVURLAsset(url: inputURL)
    let colorInfo = await VideoColorInfo.resolve(from: asset)
    let outputURL = try ShortcutVideoRenderOutput.makeURL()
    let progressHandle = IntentProgressHandle(progress)
    let render: @Sendable () async throws -> Void = {
      try await ParametricVideoExporter().export(
        asset: asset,
        recipe: FargVideoRenderRecipe(
          document: document,
          motionBlur: .disabled
        ),
        colorInfo: colorInfo,
        to: outputURL,
        onProgress: { fraction in
          progressHandle.update(fraction)
        }
      )
    }

    do {
      #if compiler(>=6.4)
      if #available(iOS 27.0, *) {
        try await performBackgroundTask(
          options: .requiresGPU,
          operation: render
        )
      } else {
        try await render()
      }
      #else
      try await render()
      #endif
    } catch {
      try? FileManager.default.removeItem(at: outputURL)
      throw error
    }

    progressHandle.update(1)
    var output = IntentFile(
      fileURL: outputURL,
      filename: "Färg.mov",
      type: .quickTimeMovie
    )
    output.removedOnCompletion = true
    return .result(value: output)
  }
}

#if compiler(>=6.4)
@available(iOS 27.0, *)
extension ApplyLUTToVideoIntent: LongRunningIntent, CancellableIntent {}
#endif

/// User-facing failures reported by the background rendering action.
private nonisolated enum ApplyLUTToVideoError: LocalizedError {
  case lutUnavailable
  case videoImportFailed(String)

  var errorDescription: String? {
    switch self {
    case .lutUnavailable:
      return "That LUT is no longer available. Choose another LUT."
    case .videoImportFailed(let reason):
      return "Färg couldn't import that video. \(reason)"
    }
  }
}

/// Creates unique result files whose lifetime is handed to Shortcuts.
private nonisolated enum ShortcutVideoRenderOutput {

  static func makeURL() throws -> URL {
    let directory = FileManager.default.urls(
      for: .cachesDirectory,
      in: .userDomainMask
    )[0].appendingPathComponent("ShortcutRenders", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    return directory.appendingPathComponent(
      "Färg-\(UUID().uuidString).mov"
    )
  }
}

/// Bridges the exporter's Sendable progress callback to App Intents progress.
private nonisolated final class IntentProgressHandle: @unchecked Sendable {

  private let lock = NSLock()
  private let progress: Progress
  private var lastCompletedUnitCount: Int64 = 0

  init(_ progress: Progress) {
    self.progress = progress
    progress.totalUnitCount = 100
    progress.localizedDescription = "Applying LUT"
  }

  func update(_ fraction: Double) {
    let completedUnitCount = Int64(
      (min(max(fraction, 0), 1) * 100).rounded(.down)
    )

    lock.lock()
    defer { lock.unlock() }
    guard completedUnitCount >= lastCompletedUnitCount else { return }
    lastCompletedUnitCount = completedUnitCount
    progress.completedUnitCount = completedUnitCount
    progress.localizedAdditionalDescription = "\(completedUnitCount)% complete"
  }
}
