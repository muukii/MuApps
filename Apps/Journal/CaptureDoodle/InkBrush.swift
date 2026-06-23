import CoreGraphics
import simd

/// RGBA ink color in extended sRGB-ish 0...1 components. Kept UI-framework-free
/// so the model layer doesn't depend on SwiftUI.
public struct InkColor: Equatable, Sendable {
  public var red: Double
  public var green: Double
  public var blue: Double
  public var alpha: Double

  public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
    self.red = red
    self.green = green
    self.blue = blue
    self.alpha = alpha
  }

  public static let black = InkColor(red: 0, green: 0, blue: 0)
  public static let white = InkColor(red: 1, green: 1, blue: 1)

  var simd: SIMD4<Float> {
    SIMD4(Float(red), Float(green), Float(blue), Float(alpha))
  }
}

/// A brush configuration. `spacing` is the stamp interval as a fraction of
/// `size` (smaller → smoother, more stamps). Mirrors Brightroom's
/// `EditingCanvasBrush`, with an added `color` since ink is pigment, not a mask.
public struct InkBrush: Equatable, Sendable {
  public var size: Double
  public var hardness: Double
  public var opacity: Double
  public var spacing: Double
  public var color: InkColor

  public init(
    size: Double = 14,
    hardness: Double = 0.75,
    opacity: Double = 1,
    spacing: Double = 0.05,
    color: InkColor = .black
  ) {
    self.size = size
    self.hardness = hardness
    self.opacity = opacity
    self.spacing = spacing
    self.color = color
  }
}

/// Stroke smoothing configuration, ported from Brightroom. `.bezier` at strength
/// `0.85` is the proven default (velocity-aware lag + streaming cubic Bézier).
public struct InkSmoothing: Equatable, Sendable {

  public enum Algorithm: String, CaseIterable, Sendable, Identifiable {
    case raw
    case bezier
    case catmullRom
    case movingAverage

    public var id: String { rawValue }
  }

  public var algorithm: Algorithm
  public var strength: Double

  public init(algorithm: Algorithm = .bezier, strength: Double = 0.85) {
    self.algorithm = algorithm
    self.strength = strength
  }
}
