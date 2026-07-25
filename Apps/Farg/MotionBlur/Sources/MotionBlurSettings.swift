//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import Foundation
import VideoToolbox

/// User-authored parameters for Optical Flow motion blur.
///
/// `strength` intentionally mirrors VideoToolbox's documented 1...100 range.
/// It is not labeled as a shutter angle because Apple does not define a
/// physical shutter-angle conversion for `VTMotionBlurParameters`.
public struct MotionBlurSettings: Equatable, Sendable {

  /// The range accepted by `VTMotionBlurParameters`.
  public static let strengthRange = 1...100

  /// A recipe that bypasses all temporal processing.
  public static let disabled = MotionBlurSettings(isEnabled: false)

  /// Whether the temporal renderer participates in preview and export.
  public var isEnabled: Bool

  /// Optical Flow motion-blur strength in VideoToolbox units.
  public var strength: Int {
    didSet {
      strength = Self.clampedStrength(strength)
    }
  }

  /// Creates motion-blur settings, normalizing strength to VideoToolbox's
  /// supported range.
  public init(
    isEnabled: Bool = false,
    strength: Int = 50
  ) {
    self.isEnabled = isEnabled
    self.strength = Self.clampedStrength(strength)
  }

  private static func clampedStrength(_ strength: Int) -> Int {
    min(max(strength, strengthRange.lowerBound), strengthRange.upperBound)
  }
}

/// Runtime support for Färg's Optical Flow motion-blur backend.
public enum MotionBlurAvailability {

  /// Whether the current device exposes Apple's motion-blur frame processor.
  public static var isSupported: Bool {
    #if targetEnvironment(simulator)
      false
    #else
      VTMotionBlurConfiguration.isSupported
    #endif
  }
}

/// Internal quality policy used when configuring VideoToolbox.
public enum MotionBlurQuality: Equatable, Sendable {
  /// Prioritizes interactive preview and ordinary export throughput.
  case normal

  /// Requests VideoToolbox's higher-quality processing mode.
  case quality
}
