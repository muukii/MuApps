//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import Foundation
import Observation

/// A one-shot editor request produced by an App Intent.
///
/// The video URL already points into the app's caches. Keeping the copied file
/// and the selected LUT identity together prevents SwiftUI launch timing from
/// separating the two inputs.
nonisolated struct ShortcutVideoImportRequest: Identifiable, Equatable, Sendable {

  /// Identifies one delivery so a superseded SwiftUI task can be cancelled.
  let id: UUID

  /// A movie file owned by Färg.
  let videoURL: URL

  /// The stable identity of the LUT selected in Shortcuts.
  let lutID: String
}

/// Buffers the most recent Shortcuts request until `RootView` consumes it.
///
/// Foreground App Intents and SwiftUI scene creation do not have a guaranteed
/// ordering. This process-local inbox supports both cold launch and an already
/// running scene without coupling the intent directly to view state.
@MainActor
@Observable
final class ShortcutVideoImportCenter {

  static let shared = ShortcutVideoImportCenter()

  private(set) var pendingRequest: ShortcutVideoImportRequest?

  private init() {}

  /// Replaces any request that the editor has not consumed yet.
  func submit(videoURL: URL, lutID: String) {
    pendingRequest = ShortcutVideoImportRequest(
      id: UUID(),
      videoURL: videoURL,
      lutID: lutID
    )
  }

  /// Claims the expected request exactly once.
  func take(id: ShortcutVideoImportRequest.ID) -> ShortcutVideoImportRequest? {
    guard pendingRequest?.id == id else { return nil }
    defer { pendingRequest = nil }
    return pendingRequest
  }
}
