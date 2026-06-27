import Foundation
import Observation
import SwiftUI
import UIKit

/// Scene-local notification presenter for the Journal app.
///
/// `RootView` owns one center per scene and injects it through SwiftUI's
/// type-based environment. Feature views post lightweight `JournalNotification`
/// values through this model; `JournalNotificationHost` is the only view that
/// decides how those values are rendered.
@MainActor
@Observable
final class JournalNotificationCenter {

  /// The notification currently visible in the app overlay.
  private(set) var current: JournalNotification?

  @ObservationIgnored private var dismissalTask: Task<Void, Never>?

  deinit {
    dismissalTask?.cancel()
  }

  /// Presents a notification and replaces any notification already visible.
  func post(_ notification: JournalNotification) {
    dismissalTask?.cancel()
    current = notification
    playHaptic(for: notification.semantics)
    scheduleDismissalIfNeeded(for: notification)
  }

  /// Dismisses the currently visible notification when its identity still matches.
  func dismiss(id: JournalNotification.ID) {
    guard current?.id == id else { return }
    dismissalTask?.cancel()
    dismissalTask = nil
    current = nil
  }

  private func scheduleDismissalIfNeeded(for notification: JournalNotification) {
    guard case .transient(let duration) = notification.lifetime else {
      dismissalTask = nil
      return
    }

    dismissalTask = Task { [weak self] in
      do {
        try await Task.sleep(for: duration)
      } catch {
        return
      }
      self?.dismiss(id: notification.id)
    }
  }

  private func playHaptic(for semantics: JournalNotification.Semantics) {
    guard let feedbackType = semantics.notificationFeedbackType else { return }
    UINotificationFeedbackGenerator().notificationOccurred(feedbackType)
  }
}

/// A single app-local message shown by `JournalNotificationHost`.
///
/// Keep this type presentation-oriented: it carries localized copy, the symbol,
/// and display lifetime, but not persistence errors or domain objects. That
/// boundary lets the host stay generic while feature code decides what the user
/// should be told.
struct JournalNotification: Identifiable, Sendable {

  /// Coarse user-facing meaning for the notification.
  ///
  /// The notification center uses this value for haptics, and the overlay host
  /// uses it for presentation details such as icon styling.
  enum Semantics: Sendable {
    case info
    case success
    case warning
    case failure
  }

  /// How long the notification should stay visible.
  enum Lifetime: Sendable {
    case transient(Duration)
    case persistent
  }

  /// Stable identity for transitions and targeted dismissal.
  let id: UUID

  /// User-facing meaning that drives haptics and presentation tone.
  let semantics: Semantics

  /// Primary message shown in the notification bar.
  let title: LocalizedStringResource

  /// Optional supporting text shown under the title.
  let message: LocalizedStringResource?

  /// SF Symbol shown at the leading edge.
  let systemImage: String

  /// Display lifetime managed by `JournalNotificationCenter`.
  let lifetime: Lifetime

  init(
    id: UUID = UUID(),
    semantics: Semantics,
    title: LocalizedStringResource,
    message: LocalizedStringResource? = nil,
    systemImage: String,
    lifetime: Lifetime = .transient(.seconds(3))
  ) {
    self.id = id
    self.semantics = semantics
    self.title = title
    self.message = message
    self.systemImage = systemImage
    self.lifetime = lifetime
  }
}

private extension JournalNotification.Semantics {

  var notificationFeedbackType: UINotificationFeedbackGenerator.FeedbackType? {
    switch self {
    case .info:
      nil
    case .success:
      .success
    case .warning:
      .warning
    case .failure:
      .error
    }
  }
}

extension JournalNotification {

  /// Confirmation shown after the current composer thread is persisted.
  static var threadSaved: JournalNotification {
    JournalNotification(
      semantics: .success,
      title: "Saved to Journal",
      systemImage: "checkmark.circle.fill",
      lifetime: .transient(.seconds(2.4))
    )
  }

  /// Failure shown when persistence rejects the current composer thread.
  static var threadSaveFailed: JournalNotification {
    JournalNotification(
      semantics: .failure,
      title: "Could not save",
      message: "Your draft stayed on screen.",
      systemImage: "exclamationmark.triangle.fill",
      lifetime: .persistent
    )
  }
}
