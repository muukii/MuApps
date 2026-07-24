//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import BrightroomParametric
import Foundation

/// The edit being authored: a video plus the parametric feature stack applied to
/// it. `makeDocument(using:)` is the single place the UI turns selections into a
/// `BrightroomParametric.EditingDocument` (the FeatureTree), so new features
/// (crop, adjustments, ...) plug in here without changing the render/export path.
@MainActor
@Observable
final class EditState {

  /// The picked video, or `nil` before one is chosen.
  var videoSource: VideoSource?

  /// The source video's resolved color characteristics (for output tagging /
  /// HDR messaging). `nil` until resolved after a pick.
  var colorInfo: VideoColorInfo?

  /// The selected LUT, or `nil` for the unmodified video.
  var selectedLUT: LUT?

  /// The LUT intensity (0 = original, 1 = full LUT).
  var amount: Double = 1.0

  /// Intensities at or below this are treated as "no effect".
  private static let minimumAmount = 0.001

  var hasVideo: Bool { videoSource != nil }

  /// Compiles the current selections into a parametric editing document.
  ///
  /// Today the main tree holds at most one `ColorCubeFeature`. The shape already
  /// supports appending domain/effect/local-adjustment features in order.
  func makeDocument(using library: LUTLibrary) throws -> EditingDocument {
    var features: [MainFeature] = []
    // Below the threshold the LUT contributes nothing, so emit an empty tree —
    // a literal source pass-through rather than a null color-cube evaluation.
    if let lut = selectedLUT, amount > Self.minimumAmount {
      let feature = try library.feature(for: lut, amount: amount)
      features.append(.effect(feature))
    }
    return EditingDocument(mainTree: MainTree(features: features))
  }
}
