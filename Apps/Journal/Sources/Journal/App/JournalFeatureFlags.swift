/// Compile-time gates for Journal capabilities that are not ready for every
/// shipped build.
///
/// Keep these flags close to the app target: they control user-facing entry
/// points, while lower-level models and renderers may still need to decode data
/// that was created while a feature was enabled.
enum JournalFeatureFlags {

  /// Shows Apple Journaling Suggestions capture entry points.
  ///
  /// Suggestion cards remain renderable in all builds, but creating new ones is
  /// limited to Debug while the capture flow and visual design are still under
  /// review. Native macOS never exposes the entry point because the framework
  /// is only available to iOS-family builds.
  static var isJournalingSuggestionsCaptureEnabled: Bool {
    #if DEBUG && os(iOS)
    true
    #else
    false
    #endif
  }
}
