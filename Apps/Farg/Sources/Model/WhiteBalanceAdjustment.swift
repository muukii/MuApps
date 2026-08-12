//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import BrightroomParametric
import Foundation

/// A relative white-balance correction authored before Exposure and the LUT.
///
/// Temperature and Tint are creative offsets centered at zero rather than
/// absolute capture metadata. Färg owns the ranges exposed by its editor while
/// Brightroom evaluates both axes as one coupled white-point transformation.
nonisolated struct WhiteBalanceAdjustment: Equatable, Sendable {

  /// The relative color-temperature range presented by the editor, in Kelvin.
  static let supportedTemperatureRange = -3_000.0...3_000.0

  /// The smallest color-temperature increment authored by the editor slider.
  static let temperatureStep = 50.0

  /// The green–magenta tint range presented by the editor.
  static let supportedTintRange = -100.0...100.0

  /// The smallest tint increment authored by the editor slider.
  static let tintStep = 1.0

  /// The identity adjustment used by a new editing session.
  static let neutral = WhiteBalanceAdjustment()

  /// The relative color-temperature offset in Kelvin; negative is cooler.
  var temperature: Double {
    didSet {
      temperature = Self.clamped(
        temperature,
        to: Self.supportedTemperatureRange
      )
    }
  }

  /// The relative tint offset; negative is greener and positive is magenta.
  var tint: Double {
    didSet {
      tint = Self.clamped(tint, to: Self.supportedTintRange)
    }
  }

  /// Whether both axes leave the input white point unchanged.
  var isNeutral: Bool {
    abs(temperature) <= 0.0001 && abs(tint) <= 0.0001
  }

  /// Creates an adjustment and clamps both axes to the editor's ranges.
  init(
    temperature: Double = 0,
    tint: Double = 0
  ) {
    self.temperature = Self.clamped(
      temperature,
      to: Self.supportedTemperatureRange
    )
    self.tint = Self.clamped(tint, to: Self.supportedTintRange)
  }

  /// The stable Brightroom node compiled into Färg's parametric document.
  var feature: TemperatureFeature {
    TemperatureFeature(
      id: FeatureID(rawValue: "farg.white-balance"),
      isEnabled: isNeutral == false,
      value: temperature,
      tint: tint
    )
  }

  private static func clamped(
    _ value: Double,
    to range: ClosedRange<Double>
  ) -> Double {
    min(max(value, range.lowerBound), range.upperBound)
  }
}
