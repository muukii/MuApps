import AppIntents

struct YouTubeSubtitleAppShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: OpenYouTubeVideoIntent(),
      phrases: [
        "Open \(.applicationName)",
        "Open video in \(.applicationName)"
      ],
      shortTitle: "Open Video",
      systemImageName: "play.rectangle"
    )
  }
}
