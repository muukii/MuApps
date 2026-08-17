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
final class JournalShareModel {

  private(set) var payloads: [JournalSharePayload] = []
  private(set) var warnings: [JournalShareLoadWarning] = []
  private(set) var writableVaults: [JournalWritableVault] = []
  private(set) var isLoading = true
  private(set) var isPosting = false
  private(set) var errorMessage: String?

  var selectedVaultID: VaultID?
  var comment = ""

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
  func start(inputItems: [NSExtensionItem]) {
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

  /// Commits the comment and all imported items as one Journal thread.
  ///
  /// The comment, when present, is the root card. Otherwise the first imported
  /// item is the root and subsequent items are ordered children.
  func post() {
    guard canPost, let selectedVaultID else { return }

    isPosting = true
    errorMessage = nil
    defer { isPosting = false }

    var cards = payloads.map { $0.cardDraft() }
    let normalizedComment = comment.trimmingCharacters(in: .whitespacesAndNewlines)
    if normalizedComment.isEmpty == false {
      cards.insert(.init(kind: .text, text: normalizedComment), at: 0)
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
  func hostDidDismiss() {
    guard hasFinished == false else { return }
    hasFinished = true
    loadingTask?.cancel()
    cleanUpTemporaryFiles()
  }

  private func cleanUpTemporaryFiles() {
    payloads.forEach { $0.cleanUpTemporaryFiles() }
  }
}
