import AppIntents
import Foundation
import JournalIntents
import JournalVault

/// Posts supplied text to an explicit Vault or the last successful Share destination.
///
/// Success means the card and its durable CloudKit outbox rows committed to the
/// shared local vault. The containing app owns eventual CloudKit transport and
/// rescans that outbox when it next becomes active.
struct PostTextToJournalIntent: AppIntent {
  static let title: LocalizedStringResource = "Post Text to Journal"
  static let description = IntentDescription(
    "Post text to a Journal Vault without opening the app."
  )
  static let supportedModes: IntentModes = .background
  static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

  @Parameter(
    title: "Text",
    description: "The text to post.",
    inputConnectionBehavior: .connectToPreviousIntentResult
  )
  var text: String

  @Parameter(
    title: "Vault",
    description: "Leave empty to use the most recent Tinycurve Share Vault."
  )
  var vault: JournalWritableVaultEntity?

  static var parameterSummary: some ParameterSummary {
    Summary("Post \(\.$text) to \(\.$vault)")
  }

  init() {
    text = ""
    vault = nil
  }

  init(text: String, vault: JournalWritableVaultEntity? = nil) {
    self.text = text
    self.vault = vault
  }

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    guard text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
      throw PostTextToJournalError.emptyText
    }

    let service = JournalPostingService()
    let destination = try resolveDestination(using: service)
    try service.post(
      cards: [VaultContentStore.CardDraft(kind: .text, text: text)],
      to: destination
    )

    return .result(dialog: "Posted to \(destination.title).")
  }

  @MainActor
  private func resolveDestination(
    using service: JournalPostingService
  ) throws -> JournalWritableVault {
    if let vault {
      guard let destination = vault.writableVault else {
        throw PostTextToJournalError.invalidVault
      }
      return destination
    }

    let writableVaults = try service.writableVaults()
    guard let destination = try JournalQuickCapturePreferences().selectedVault(
      from: writableVaults
    ) else {
      throw PostTextToJournalError.destinationVaultRequired
    }
    return destination
  }
}

/// User-correctable validation failures surfaced by Shortcuts and Siri.
private enum PostTextToJournalError: Error, LocalizedError {
  case emptyText
  case invalidVault
  case destinationVaultRequired

  var errorDescription: String? {
    switch self {
    case .emptyText:
      "Add text before posting to Journal."
    case .invalidVault:
      "The selected Journal Vault is invalid. Choose it again."
    case .destinationVaultRequired:
      "Choose a Vault for this Shortcut or post once from the Tinycurve Share sheet."
    }
  }
}
