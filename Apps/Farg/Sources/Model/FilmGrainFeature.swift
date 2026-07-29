//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import BrightroomParametric
import CoreImage
import Foundation

/// A parametric film-grain effect evaluated over one video frame.
///
/// The feature stores only authored parameters. Frame time arrives through
/// `FeatureEvaluationContext`, allowing the same document to render
/// deterministic still images and time-varying video without rewriting its
/// authored values. Unlike Optical Flow motion blur, grain needs no temporal
/// neighbors or device-support gate.
nonisolated struct FilmGrainFeature: ImageEffectFeatureType {

  /// The user-facing range shared by `intensity` and `size`.
  static let valueRange = 1...100

  /// The stable identity of this grain feature in the parametric document.
  var id: FeatureID

  /// Whether the grain overlay participates in preview and export.
  var isEnabled: Bool

  /// The visibility of the grain texture.
  var intensity: Int {
    didSet {
      intensity = Self.clamped(intensity)
    }
  }

  /// The relative grain-particle size.
  ///
  /// The rendered pitch resolves against the output height, so the
  /// viewport-fitted preview and the source-resolution export show the same
  /// texture scale.
  var size: Int {
    didSet {
      size = Self.clamped(size)
    }
  }

  /// Creates a film-grain feature, normalizing both values to the supported range.
  init(
    id: FeatureID = .init(),
    isEnabled: Bool = false,
    intensity: Int = 50,
    size: Int = 50
  ) {
    self.id = id
    self.isEnabled = isEnabled
    self.intensity = Self.clamped(intensity)
    self.size = Self.clamped(size)
  }

  /// Evaluates the film-grain kernel at the frame time supplied by the renderer.
  func apply(
    to image: CIImage,
    context: FeatureEvaluationContext
  ) throws -> CIImage {
    try FilmGrainRenderer.apply(
      to: image,
      renderExtent: image.extent,
      presentationTime: context.presentationTime,
      intensity: intensity,
      size: size
    )
  }

  private static func clamped(_ value: Int) -> Int {
    min(max(value, valueRange.lowerBound), valueRange.upperBound)
  }
}
