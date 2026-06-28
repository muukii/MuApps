import SwiftUI

/// A named, user-selectable color theme carrying a light and a dark `Palette`.
///
/// `Palette` carries the asset-backed color data with no identity; `Theme`
/// pairs a light/dark palette set with a stable `id` (for persistence) and a
/// display `name` (for pickers), and resolves the active surface for a
/// `ColorScheme` via `palette(for:)`. Every theme has the same shape — id, name,
/// light, dark — so this is a data bag expressed as a struct with static
/// constants rather than an enum.
public struct Theme: Identifiable, Sendable {

  public let id: String
  public let name: String
  public let light: Palette
  public let dark: Palette

  public init(id: String, name: String, light: Palette, dark: Palette) {
    self.id = id
    self.name = name
    self.light = light
    self.dark = dark
  }

  /// The palette for the given color scheme.
  public func palette(for colorScheme: ColorScheme) -> Palette {
    switch colorScheme {
    case .light: light
    case .dark: dark
    @unknown default: light
    }
  }
}

extension Theme {

  /// Warm Cream（= `.default`）
  public static let warmCream = Theme(id: "warmCream", name: "Warm Cream", assetName: "WarmCream")

  /// Soft Mocha
  public static let softMocha = Theme(id: "softMocha", name: "Soft Mocha", assetName: "SoftMocha")

  /// Midnight（基準のダークスキーム）
  public static let midnight = Theme(id: "midnight", name: "Midnight", assetName: "Midnight")

  /// Sage
  public static let sage = Theme(id: "sage", name: "Sage", assetName: "Sage")

  /// Blush
  public static let blush = Theme(id: "blush", name: "Blush", assetName: "Blush")

  /// Citrus
  public static let citrus = Theme(id: "citrus", name: "Citrus", assetName: "Citrus")

  /// Lagoon
  public static let lagoon = Theme(id: "lagoon", name: "Lagoon", assetName: "Lagoon")

  /// Berry
  public static let berry = Theme(id: "berry", name: "Berry", assetName: "Berry")

  public static let `default`: Theme = .warmCream

  /// All themes, in picker display order.
  public static let all: [Theme] = [
    .warmCream,
    .softMocha,
    .midnight,
    .sage,
    .blush,
    .citrus,
    .lagoon,
    .berry,
  ]

  /// Resolves a persisted id back to a theme, falling back to `.default` for
  /// unknown or removed ids.
  public static func with(id: String) -> Theme {
    all.first { $0.id == id } ?? .default
  }

  private init(id: String, name: String, assetName: String) {
    self.init(
      id: id,
      name: name,
      light: Palette(assetNamespace: "Theme/\(assetName)", colorScheme: .light),
      dark: Palette(assetNamespace: "Theme/\(assetName)", colorScheme: .dark)
    )
  }
}
