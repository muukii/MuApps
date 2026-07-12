/// Compile-time gates for platform-specific Journal capabilities.
///
/// Keep these flags close to the app target: they control user-facing entry
/// points, while lower-level models and renderers may still need to decode data
/// that was created while a feature was enabled.
enum JournalFeatureFlags {

  /// Shows Apple Journaling Suggestions capture entry points.
  ///
  /// Suggestion capture is available in iPhone and iPad builds so in-app menus
  /// and system Quick Capture expose the same set of actions. Native macOS never
  /// exposes it because the framework is only available to iOS-family builds.
  static var isJournalingSuggestionsCaptureEnabled: Bool {
    #if os(iOS)
    true
    #else
    false
    #endif
  }
}
