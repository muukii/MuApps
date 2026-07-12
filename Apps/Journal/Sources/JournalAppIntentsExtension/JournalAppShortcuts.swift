import AppIntents
import JournalIntents

/// Phrases and tiles Journal contributes directly to the Shortcuts app, Siri,
/// Spotlight, and Action Button action selection.
struct JournalAppShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: OpenJournalCaptureIntent(mode: .text),
      phrases: [
        "Quick capture in \(.applicationName)",
        "Write in \(.applicationName)",
      ],
      shortTitle: "Quick Capture",
      systemImageName: "square.and.pencil"
    )

    AppShortcut(
      intent: PostTextToJournalIntent(),
      phrases: [
        "Post text to \(.applicationName)",
        "Add a note to \(.applicationName)",
      ],
      shortTitle: "Post Text",
      systemImageName: "text.badge.plus"
    )
  }

  static let shortcutTileColor: ShortcutTileColor = .navy
}

/// Pulls the shared framework's App Intents metadata into this extension's
/// extraction graph.
struct JournalExtensionIntentsPackage: AppIntentsPackage {
  nonisolated(unsafe) static let includedPackages: [any AppIntentsPackage.Type] = [
    JournalAppIntentsPackage.self,
  ]
}
