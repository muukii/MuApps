import Foundation
import JournalIntents
import JournalVault
import Observation

/// Main-actor state and actions for the Journal share extension.
///
/// The model owns imported temporary files until posting succeeds or the user
/// cancels. A failed transaction intentionally retains them so the same share
/// can be retried without asking the host app to vend its providers again.
@MainActor
@Observable
public final class JournalShareModel {

  private(set) var payloads: [JournalSharePayload] = []
  private(set) var warnings: [JournalShareLoadWarning] = []
  private(set) var writableVaults: [JournalWritableVault] = []
  private(set) var isLoading = true
  private(set) var isPosting = false
  private(set) var errorMessage: String?

  var selectedVaultID: VaultID?
  var comment = ""
  var commentKind: JournalShareCommentKind = .text

  @ObservationIgnored
  private let postingService: JournalPostingService

  @ObservationIgnored
  private let contentLoader: JournalShareContentLoader

  @ObservationIgnored
  private let quickCapturePreferences: JournalQuickCapturePreferences

  @ObservationIgnored
  private let onComplete: @MainActor () -> Void

  @ObservationIgnored
  private let onCancel: @MainActor () -> Void

  @ObservationIgnored
  private var loadingTask: Task<Void, Never>?

  @ObservationIgnored
  private var hasFinished = false

  /// Creates the model the extension host presents, backed by Journal's real
  /// App Group services.
  ///
  /// Service injection stays module-internal on purpose: the host process has
  /// no business choosing a posting service or a preferences suite.
  public convenience init(
    onComplete: @escaping @MainActor () -> Void,
    onCancel: @escaping @MainActor () -> Void
  ) {
    self.init(
      postingService: .init(),
      contentLoader: .init(),
      quickCapturePreferences: .init(),
      onComplete: onComplete,
      onCancel: onCancel
    )
  }

  init(
    postingService: JournalPostingService = .init(),
    contentLoader: JournalShareContentLoader = .init(),
    quickCapturePreferences: JournalQuickCapturePreferences = .init(),
    onComplete: @escaping @MainActor () -> Void,
    onCancel: @escaping @MainActor () -> Void
  ) {
    self.postingService = postingService
    self.contentLoader = contentLoader
    self.quickCapturePreferences = quickCapturePreferences
    self.onComplete = onComplete
    self.onCancel = onCancel
  }

  /// Loads writable vaults and materializes the host app's transient providers.
  public func start(inputItems: [NSExtensionItem]) {
    loadingTask?.cancel()
    isLoading = true
    errorMessage = nil

    loadingTask = Task { [weak self] in
      guard let self else { return }
      do {
        writableVaults = try postingService.writableVaults()
        selectedVaultID = try quickCapturePreferences
          .selectedVault(from: writableVaults)?.id
        let result = try await contentLoader.load(from: inputItems)
        try Task.checkCancellation()
        payloads = result.payloads
        warnings = result.warnings
        isLoading = false
      } catch is CancellationError {
        // Cancellation is owned by `cancel()` or host dismissal; neither needs
        // to flash a transient error while the extension is closing.
      } catch {
        isLoading = false
        errorMessage = error.localizedDescription
      }
    }
  }

  /// Whether the current review state has everything required for a post.
  var canPost: Bool {
    isLoading == false
      && isPosting == false
      && selectedVaultID != nil
      && payloads.isEmpty == false
  }

  /// Commits all imported items and the comment as one Journal post.
  ///
  /// The first imported item is always the root, so the shared content owns the
  /// entry. Remaining items and the comment become ordered children, keeping the
  /// comment an annotation nested under the share rather than its subject. The
  /// comment is written with the selected kind, so a Todo comment becomes an
  /// actionable child rather than a written note.
  func post() {
    guard canPost, let selectedVaultID else { return }

    isPosting = true
    errorMessage = nil
    defer { isPosting = false }

    var cards = payloads.map { $0.cardDraft() }
    let normalizedComment = comment.trimmingCharacters(in: .whitespacesAndNewlines)
    if normalizedComment.isEmpty == false {
      cards.append(.init(kind: commentKind.cardKind, text: normalizedComment))
    }

    do {
      try postingService.post(cards: cards, to: selectedVaultID)
      // The Card transaction is already durable. Preference failure must not
      // invite a retry that would duplicate the successfully posted content.
      try? quickCapturePreferences.setSelectedVaultID(selectedVaultID)
      hasFinished = true
      cleanUpTemporaryFiles()
      onComplete()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  /// Cancels provider loading, cleans imports, and returns control to the host.
  func cancel() {
    guard isPosting == false, hasFinished == false else { return }
    hasFinished = true
    loadingTask?.cancel()
    cleanUpTemporaryFiles()
    onCancel()
  }

  /// Stops outstanding work and cleans files when the host dismisses the
  /// extension without using Journal's Cancel button.
  public func hostDidDismiss() {
    guard hasFinished == false else { return }
    hasFinished = true
    loadingTask?.cancel()
    cleanUpTemporaryFiles()
  }

  private func cleanUpTemporaryFiles() {
    payloads.forEach { $0.cleanUpTemporaryFiles() }
  }
}

// MARK: - Comment kind

/// Modality the user picks for the optional comment authored in the share sheet.
///
/// Only the two body-backed kinds are offered. Every other `Card.Kind` arrives
/// as an imported payload and is never authored on this surface.
enum JournalShareCommentKind: Hashable, Sendable {
  case text
  case todo

  /// Card kind written for a non-empty comment. A new Todo is always
  /// incomplete, which `CardDraft` already enforces by leaving `completedAt` nil.
  var cardKind: Card.Kind {
    switch self {
    case .text:
      return .text
    case .todo:
      return .todo
    }
  }
}
