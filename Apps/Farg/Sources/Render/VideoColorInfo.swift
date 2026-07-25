//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import AVFoundation
import CoreMedia
import Foundation

/// The color characteristics of a source video, used to tag the rendered output
/// so the exported file (and preview) are interpreted in the same color space
/// the source was authored in.
///
/// Without this the `AVMutableVideoComposition` output is untagged and a
/// Display-P3 source exports with shifted / desaturated color versus the preview.
nonisolated struct VideoColorInfo: Sendable, Equatable {

  var colorPrimaries: String?
  var transferFunction: String?
  var yCbCrMatrix: String?

  /// Whether the source uses an HDR transfer function (HLG or PQ).
  var isHDR: Bool

  static let sdrRec709 = VideoColorInfo(
    colorPrimaries: AVVideoColorPrimaries_ITU_R_709_2,
    transferFunction: AVVideoTransferFunction_ITU_R_709_2,
    yCbCrMatrix: AVVideoYCbCrMatrix_ITU_R_709_2,
    isHDR: false
  )

  /// Reads the color attachments from a source asset's first video track.
  static func resolve(from asset: AVAsset) async -> VideoColorInfo {
    guard
      let track = try? await asset.loadTracks(withMediaType: .video).first,
      let formats = try? await track.load(.formatDescriptions),
      let format = formats.first
    else {
      return .sdrRec709
    }

    func extension_(_ key: CFString) -> String? {
      CMFormatDescriptionGetExtension(format, extensionKey: key) as? String
    }

    let transfer = extension_(kCMFormatDescriptionExtension_TransferFunction)
    let isHDR =
      transfer == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String)
      || transfer == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String)

    return VideoColorInfo(
      colorPrimaries: extension_(kCMFormatDescriptionExtension_ColorPrimaries),
      transferFunction: transfer,
      yCbCrMatrix: extension_(kCMFormatDescriptionExtension_YCbCrMatrix),
      isHDR: isHDR
    )
  }

  /// Tags the composition's output color.
  ///
  /// The current Core Image pipeline is SDR-referenced, so HDR sources are
  /// rendered and tagged as SDR Rec.709 (a deliberate, predictable downgrade)
  /// rather than emitting a mislabeled HDR file. SDR / Display-P3 sources keep
  /// their own primaries.
  func apply(to composition: AVMutableVideoComposition) {
    let tags = isHDR ? VideoColorInfo.sdrRec709 : self
    composition.colorPrimaries = tags.colorPrimaries ?? AVVideoColorPrimaries_ITU_R_709_2
    composition.colorTransferFunction = tags.transferFunction ?? AVVideoTransferFunction_ITU_R_709_2
    composition.colorYCbCrMatrix = tags.yCbCrMatrix ?? AVVideoYCbCrMatrix_ITU_R_709_2
  }
}
