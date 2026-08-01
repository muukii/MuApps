//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import BrightroomParametric
import Foundation

/// An exposure adjustment authored in photographic exposure-value units.
///
/// Färg applies this value before the selected LUT so changing exposure also
/// changes the LUT's color response. The type owns the editor's supported
/// range while Brightroom remains responsible for evaluating the image effect.
nonisolated struct ExposureAdjustment: Equatable, Sendable {

  /// The exposure-value range presented by the editor.
  static let supportedEVRange = -2.0...2.0

  /// The smallest exposure-value increment authored by the editor slider.
  static let evStep = 0.1

  /// The identity adjustment used by a new editing session.
  static let neutral = ExposureAdjustment()

  /// The authored exposure offset in EV.
  var ev: Double {
    didSet {
      ev = Self.clamped(ev)
    }
  }

  /// Whether the adjustment leaves input color values unchanged.
  var isNeutral: Bool {
    abs(ev) <= 0.0001
  }

  /// Creates an adjustment and clamps it to the editor's supported range.
  init(ev: Double = 0) {
    self.ev = Self.clamped(ev)
  }

  /// The stable Brightroom node compiled into Färg's parametric document.
  var feature: ExposureFeature {
    ExposureFeature(
      id: FeatureID(rawValue: "farg.exposure"),
      isEnabled: isNeutral == false,
      value: ev
    )
  }

  private static func clamped(_ value: Double) -> Double {
    min(max(value, supportedEVRange.lowerBound), supportedEVRange.upperBound)
  }
}
