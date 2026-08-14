import Foundation
import SwiftUI

/// Establishes Journal's appearance environment for one scene subtree.
///
/// The host resolves the persisted appearance preference into the concrete
/// color scheme observed by its descendants. A System preference follows the
/// scheme inherited by the host; Light and Dark replace it only inside the
/// hosted subtree.
///
/// Install the host above a scene's root content. Independent SwiftUI scenes
/// must each install their own host because environments don't cross scene
/// boundaries.
struct JournalSceneAppearanceHost<Content: View>: View {

  @Environment(\.colorScheme) private var inheritedColorScheme

  @AppStorage(JournalDefaults.appearancePreferenceID)
  private var appearancePreferenceID: String = JournalAppearancePreference.system.rawValue

  private let content: Content

  /// Creates a scene appearance boundary backed by Journal's stored preferences.
  ///
  /// - Parameters:
  ///   - defaults: The defaults store containing Journal's appearance values.
  ///     The injectable store keeps previews and tests isolated from live app settings.
  ///   - content: The scene subtree that receives the resolved color scheme.
  init(
    defaults: UserDefaults = .standard,
    @ViewBuilder content: () -> Content
  ) {
    _appearancePreferenceID = AppStorage(
      wrappedValue: JournalAppearancePreference.system.rawValue,
      JournalDefaults.appearancePreferenceID,
      store: defaults
    )
    self.content = content()
  }

  var body: some View {
    content
      .environment(\.colorScheme, resolvedColorScheme)
  }

  private var resolvedColorScheme: ColorScheme {
    JournalAppearancePreference.with(id: appearancePreferenceID).colorScheme
      ?? inheritedColorScheme
  }
}
