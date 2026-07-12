import SwiftUI

/// A user-selectable key color for interactive Journal chrome.
///
/// Journal's surfaces remain neutral so authored content owns the screen's
/// color. An accent is limited to selection, focus, and primary actions. Its
/// stable `id` is persisted by the app; `assetName` points to the existing
/// light/dark-aware tint assets in MuColor.
public struct AccentColor: Identifiable, Sendable {

  public let id: String
  public let name: LocalizedStringResource
  let assetName: String

  private init(id: String, name: LocalizedStringResource, assetName: String) {
    self.id = id
    self.name = name
    self.assetName = assetName
  }
}

extension AccentColor {

  public static let forest = AccentColor(id: "forest", name: "Forest", assetName: "Forest")
  public static let cobalt = AccentColor(id: "cobalt", name: "Cobalt", assetName: "Cobalt")
  public static let vermilion = AccentColor(id: "vermilion", name: "Vermilion", assetName: "Vermilion")
  public static let orchid = AccentColor(id: "orchid", name: "Orchid", assetName: "Blush")
  public static let amber = AccentColor(id: "amber", name: "Amber", assetName: "Citrus")

  public static let `default`: AccentColor = .forest

  /// All accents in picker display order.
  public static let all: [AccentColor] = [
    .forest,
    .cobalt,
    .vermilion,
    .orchid,
    .amber,
  ]

  /// Resolves a persisted accent or legacy theme id.
  ///
  /// The legacy aliases preserve existing user choices when the former
  /// full-surface themes are replaced by neutral surfaces plus one key color.
  public static func with(id: String) -> AccentColor {
    switch id {
    case "forest", "sage": .forest
    case "cobalt", "lagoon", "midnight": .cobalt
    case "vermilion": .vermilion
    case "orchid", "blush": .orchid
    case "amber", "citrus", "warmCream", "blackWhite": .amber
    default: .default
    }
  }
}
