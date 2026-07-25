//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

@preconcurrency import AVFoundation
import Foundation
import Observation

/// A video opened from its original Photos or Files storage.
///
/// Photos sources retain the `AVAsset` supplied by PhotoKit. Files sources keep
/// their security-scoped access alive for exactly as long as the edit/export
/// graph retains this value, so an external-volume movie is never copied into
/// the app container merely to make its URL stable.
nonisolated struct VideoSource: Identifiable, Equatable, Sendable {

  /// Identifies where the media bytes remain while Färg reads them.
  enum Origin: Sendable {
    case photoLibrary(localIdentifier: String)
    case securityScopedFile(URL)
    case appOwnedFile(URL)
  }

  let id: UUID
  let origin: Origin
  let asset: AVAsset

  /// Retains a balanced Files authorization across lazy AVFoundation reads.
  private let fileAccess: SecurityScopedFileAccess?

  /// Creates a source for an ephemeral input that was already copied by Färg.
  init(appOwnedURL: URL) {
    self.id = UUID()
    self.origin = .appOwnedFile(appOwnedURL)
    self.asset = AVURLAsset(url: appOwnedURL)
    self.fileAccess = nil
  }

  /// Creates a source backed by PhotoKit without exporting its media resource.
  init(photoLibraryAsset: AVAsset, localIdentifier: String) {
    self.id = UUID()
    self.origin = .photoLibrary(localIdentifier: localIdentifier)
    self.asset = photoLibraryAsset
    self.fileAccess = nil
  }

  /// Opens one user-selected Files URL in place for the current edit session.
  init(securityScopedURL: URL) throws {
    let access = try SecurityScopedFileAccess(url: securityScopedURL)
    self.id = UUID()
    self.origin = .securityScopedFile(securityScopedURL)
    self.asset = AVURLAsset(url: securityScopedURL)
    self.fileAccess = access
  }

  static func == (lhs: VideoSource, rhs: VideoSource) -> Bool {
    lhs.id == rhs.id
  }
}

/// A stateful movie in the editor's ordered video collection.
///
/// A clip receives its stable identity as soon as the user commits a picker
/// selection. It then owns the complete transition from queued resolution to a
/// renderable source. Color metadata belongs to the clip rather than the shared
/// edit recipe because a batch may mix SDR, Display-P3, and HDR sources.
@MainActor
@Observable
final class VideoClip: Identifiable {

  /// Source-specific values that become valid atomically after loading.
  struct Content {
    let source: VideoSource
    let displayName: String
    let colorInfo: VideoColorInfo
  }

  /// The mutually exclusive phases of one clip's import lifecycle.
  enum State {
    /// The clip has a loading operation but sequential import has not started it.
    case queued
    /// Färg is resolving and inspecting the selected movie.
    case loading
    /// The movie is ready for preview and export.
    case ready(Content)
    /// The selected movie could not be prepared.
    case failed(message: String)
  }

  /// Resolves one selected Photos or Files item into renderable clip content.
  typealias LoadingOperation = @MainActor () async throws -> Content

  let id: UUID

  private(set) var state: State

  @ObservationIgnored
  private var loadingOperation: LoadingOperation?

  /// The renderable content, or `nil` until loading succeeds.
  var content: Content? {
    guard case .ready(let content) = state else { return nil }
    return content
  }

  /// Whether this clip is queued or actively loading.
  var isPreparing: Bool {
    switch state {
    case .queued, .loading:
      true
    case .ready, .failed:
      false
    }
  }

  /// Whether preview and export can consume this clip.
  var isReady: Bool {
    content != nil
  }

  /// The user-presentable reason loading failed, when available.
  var failureMessage: String? {
    guard case .failed(let message) = state else { return nil }
    return message
  }

  init(
    source: VideoSource,
    displayName: String,
    colorInfo: VideoColorInfo
  ) {
    self.id = source.id
    self.state = .ready(
      Content(
        source: source,
        displayName: displayName,
        colorInfo: colorInfo
      )
    )
  }

  /// Creates a queued clip whose source will be resolved on demand.
  init(
    id: UUID = UUID(),
    loadingOperation: @escaping LoadingOperation
  ) {
    self.id = id
    self.state = .queued
    self.loadingOperation = loadingOperation
  }

  /// Runs this clip's pending operation and publishes one atomic ready value.
  func load() async throws {
    guard let loadingOperation else {
      return
    }
    guard case .queued = state else {
      return
    }

    state = .loading

    do {
      let content = try await loadingOperation()
      try Task.checkCancellation()
      state = .ready(content)
      self.loadingOperation = nil
    } catch is CancellationError {
      state = .queued
      throw CancellationError()
    } catch {
      state = .failed(message: error.localizedDescription)
      self.loadingOperation = nil
      throw error
    }
  }
}

/// Holds one balanced security-scope claim for a Files-backed movie.
///
/// AVFoundation reads movie samples lazily, including after preview setup has
/// returned. Releasing the scope at the picker callback would therefore make a
/// valid external-drive URL fail later during playback or background export.
private nonisolated final class SecurityScopedFileAccess: @unchecked Sendable {

  let url: URL

  init(url: URL) throws {
    guard url.startAccessingSecurityScopedResource() else {
      throw VideoSourceAccessError.accessDenied(fileName: url.lastPathComponent)
    }
    self.url = url
  }

  deinit {
    url.stopAccessingSecurityScopedResource()
  }
}

/// Failures establishing durable access to a user-selected source movie.
private nonisolated enum VideoSourceAccessError: LocalizedError, Sendable {
  case accessDenied(fileName: String)

  var errorDescription: String? {
    switch self {
    case .accessDenied(let fileName):
      return "Färg couldn't access “\(fileName)” in Files."
    }
  }
}
