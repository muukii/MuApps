import SwiftUI

/// A stable, user-facing identity for every light available in Calm Light.
///
/// Raw values intentionally preserve the page identifiers used by earlier
/// releases so a person's last-selected light continues to restore correctly.
enum LightScene: Int, CaseIterable, Identifiable {

  case solarField = 7
  case ambientFog = 0
  case aurora = 1
  case plasma = 2
  case firelight = 5
  case smoke = 6

  var id: Int { rawValue }

  var title: LocalizedStringResource {
    switch self {
    case .solarField:
      "Solar Field"
    case .ambientFog:
      "Amber Fog"
    case .aurora:
      "Aurora"
    case .plasma:
      "Color Tide"
    case .firelight:
      "Firelight"
    case .smoke:
      "Moon Smoke"
    }
  }

  var summary: LocalizedStringResource {
    switch self {
    case .solarField:
      "A living red-to-gold halo"
    case .ambientFog:
      "Slow currents of warm light"
    case .aurora:
      "Cool ribbons moving upward"
    case .plasma:
      "Saturated color in motion"
    case .firelight:
      "A low and restless glow"
    case .smoke:
      "Soft monochrome drift"
    }
  }

  var adjustmentHint: LocalizedStringResource {
    switch self {
    case .solarField:
      "Drag to place the glow"
    case .ambientFog:
      "Drag across for motion and upward for depth"
    case .aurora:
      "Drag across for motion and upward for height"
    case .plasma:
      "Drag across for motion and upward for detail"
    case .firelight:
      "Drag across for motion and upward for height"
    case .smoke:
      "Drag across for motion and upward for density"
    }
  }

  var positionText: String {
    let position = Self.allCases.firstIndex(of: self).map { $0 + 1 } ?? 1
    return "\(position.formatted(.number.precision(.integerLength(2)))) / \(Self.allCases.count.formatted(.number.precision(.integerLength(2))))"
  }
}
