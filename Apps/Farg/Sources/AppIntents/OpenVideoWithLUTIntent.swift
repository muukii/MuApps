//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import AppIntents
import Foundation
import UniformTypeIdentifiers

/// Opens a Shortcuts-supplied movie in the editor with a selected LUT.
///
/// The intent runs in the containing app because the requested outcome is an
/// interactive edit, not a headless export. The temporary `IntentFile` is
/// copied before `perform()` returns.
struct OpenVideoWithLUTIntent: AppIntent {

  static let title: LocalizedStringResource = "Open Video with LUT"
  static let description = IntentDescription(
    "Open a video in Färg with a LUT already selected."
  )
  static let supportedModes: IntentModes = .foreground(.immediate)
  static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

  @Parameter(
    title: "Video",
    description: "The video to open.",
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
    Summary("Open \(\.$video) with \(\.$lutID)")
  }

  init() {}

  @MainActor
  func perform() async throws -> some IntentResult {
    guard LUTLibrary().luts.contains(where: { $0.id == lutID }) else {
      throw OpenVideoWithLUTError.lutUnavailable
    }

    let videoURL: URL
    do {
      videoURL = try await ShortcutVideoFileImporter.copyToAppCache(video)
    } catch {
      throw OpenVideoWithLUTError.videoImportFailed(error.localizedDescription)
    }

    ShortcutVideoImportCenter.shared.submit(
      videoURL: videoURL,
      lutID: lutID
    )
    return .result()
  }
}

/// User-facing failures reported by the Shortcuts action.
private nonisolated enum OpenVideoWithLUTError: LocalizedError {
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

/// Moves an ephemeral `IntentFile` representation into app-owned storage.
nonisolated enum ShortcutVideoFileImporter {

  static func copyToAppCache(_ file: IntentFile) async throws -> URL {
    try await file.withFile(
      contentType: .movie,
      allowOpenInPlace: true
    ) { sourceURL, _ in
      let fileManager = FileManager.default
      let directory = fileManager.urls(
        for: .cachesDirectory,
        in: .userDomainMask
      )[0].appendingPathComponent("ShortcutVideos", isDirectory: true)
      try fileManager.createDirectory(
        at: directory,
        withIntermediateDirectories: true
      )

      let sourceExtension = sourceURL.pathExtension
      let fileExtension = sourceExtension.isEmpty ? "mov" : sourceExtension
      let destination = directory.appendingPathComponent(
        "\(UUID().uuidString).\(fileExtension)"
      )
      try fileManager.copyItem(at: sourceURL, to: destination)
      return destination
    }
  }
}
