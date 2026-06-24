import HexColorMacro
import SwiftUI

/// A named, user-selectable color theme carrying a light and a dark `Palette`.
///
/// `Palette` is the raw color data with no identity; `Theme` pairs a light/dark
/// palette set with a stable `id` (for persistence) and a display `name` (for
/// pickers), and resolves the active surface for a `ColorScheme` via
/// `palette(for:)`. Every theme has the same shape — id, name, light, dark — so
/// this is a data bag expressed as a struct with static constants rather than an
/// enum.
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
  public static let warmCream = Theme(
    id: "warmCream",
    name: "Warm Cream",
    light: Palette(
      tint: #hexColor("#C56B43", colorSpace: .displayP3),
      primaryContainer: #hexColor("#F2E9D8", colorSpace: .displayP3),
      onPrimaryContainer: #hexColor("#2A241D", colorSpace: .displayP3),
      secondaryContainer: #hexColor("#F3DAD0", colorSpace: .displayP3),
      onSecondaryContainer: #hexColor("#2A241D", colorSpace: .displayP3)
    ),
    dark: Palette(
      tint: #hexColor("#E0915F", colorSpace: .displayP3),
      primaryContainer: #hexColor("#231F19", colorSpace: .displayP3),
      onPrimaryContainer: #hexColor("#EFE7D8", colorSpace: .displayP3),
      secondaryContainer: #hexColor("#3A2F26", colorSpace: .displayP3),
      onSecondaryContainer: #hexColor("#EFE7D8", colorSpace: .displayP3)
    )
  )

  /// Soft Mocha
  public static let softMocha = Theme(
    id: "softMocha",
    name: "Soft Mocha",
    light: Palette(
      tint: #hexColor("#A5573A", colorSpace: .displayP3),
      primaryContainer: #hexColor("#E4D7C3", colorSpace: .displayP3),
      onPrimaryContainer: #hexColor("#322A20", colorSpace: .displayP3),
      secondaryContainer: #hexColor("#D9C3A4", colorSpace: .displayP3),
      onSecondaryContainer: #hexColor("#322A20", colorSpace: .displayP3)
    ),
    dark: Palette(
      tint: #hexColor("#C9805E", colorSpace: .displayP3),
      primaryContainer: #hexColor("#26201A", colorSpace: .displayP3),
      onPrimaryContainer: #hexColor("#E9DDCB", colorSpace: .displayP3),
      secondaryContainer: #hexColor("#403428", colorSpace: .displayP3),
      onSecondaryContainer: #hexColor("#E9DDCB", colorSpace: .displayP3)
    )
  )

  /// Midnight（基準のダークスキーム）
  public static let midnight = Theme(
    id: "midnight",
    name: "Midnight",
    light: Palette(
      tint: #hexColor("#C0792F", colorSpace: .displayP3),
      primaryContainer: #hexColor("#EDEEF2", colorSpace: .displayP3),
      onPrimaryContainer: #hexColor("#20242E", colorSpace: .displayP3),
      secondaryContainer: #hexColor("#DDE1EC", colorSpace: .displayP3),
      onSecondaryContainer: #hexColor("#20242E", colorSpace: .displayP3)
    ),
    dark: Palette(
      tint: #hexColor("#E0A45E", colorSpace: .displayP3),
      primaryContainer: #hexColor("#20242E", colorSpace: .displayP3),
      onPrimaryContainer: #hexColor("#ECEAE2", colorSpace: .displayP3),
      secondaryContainer: #hexColor("#33384A", colorSpace: .displayP3),
      onSecondaryContainer: #hexColor("#ECEAE2", colorSpace: .displayP3)
    )
  )

  /// Sage
  public static let sage = Theme(
    id: "sage",
    name: "Sage",
    light: Palette(
      tint: #hexColor("#5E7C4F", colorSpace: .displayP3),
      primaryContainer: #hexColor("#E2E7DC", colorSpace: .displayP3),
      onPrimaryContainer: #hexColor("#2B3326", colorSpace: .displayP3),
      secondaryContainer: #hexColor("#D2E0C6", colorSpace: .displayP3),
      onSecondaryContainer: #hexColor("#2B3326", colorSpace: .displayP3)
    ),
    dark: Palette(
      tint: #hexColor("#8DA877", colorSpace: .displayP3),
      primaryContainer: #hexColor("#1C211A", colorSpace: .displayP3),
      onPrimaryContainer: #hexColor("#E3EAD9", colorSpace: .displayP3),
      secondaryContainer: #hexColor("#2D3528", colorSpace: .displayP3),
      onSecondaryContainer: #hexColor("#E3EAD9", colorSpace: .displayP3)
    )
  )

  /// Blush
  public static let blush = Theme(
    id: "blush",
    name: "Blush",
    light: Palette(
      tint: #hexColor("#C2607A", colorSpace: .displayP3),
      primaryContainer: #hexColor("#F3E3E4", colorSpace: .displayP3),
      onPrimaryContainer: #hexColor("#3A2A2D", colorSpace: .displayP3),
      secondaryContainer: #hexColor("#F4D4D9", colorSpace: .displayP3),
      onSecondaryContainer: #hexColor("#3A2A2D", colorSpace: .displayP3)
    ),
    dark: Palette(
      tint: #hexColor("#D98AA0", colorSpace: .displayP3),
      primaryContainer: #hexColor("#241A1D", colorSpace: .displayP3),
      onPrimaryContainer: #hexColor("#F1DCDF", colorSpace: .displayP3),
      secondaryContainer: #hexColor("#3B2A2E", colorSpace: .displayP3),
      onSecondaryContainer: #hexColor("#F1DCDF", colorSpace: .displayP3)
    )
  )

  public static let `default`: Theme = .warmCream

  /// All themes, in picker display order.
  public static let all: [Theme] = [.warmCream, .softMocha, .midnight, .sage, .blush]

  /// Resolves a persisted id back to a theme, falling back to `.default` for
  /// unknown or removed ids.
  public static func with(id: String) -> Theme {
    all.first { $0.id == id } ?? .default
  }
}
