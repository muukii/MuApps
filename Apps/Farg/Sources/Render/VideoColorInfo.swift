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

  /// The concrete output supported when no LUT overrides the source contract.
  ///
  /// The current Core Image pipeline is SDR-referenced, so HLG and PQ inputs
  /// are intentionally materialized as SDR Rec.709 instead of being emitted
  /// with misleading HDR metadata. Non-HDR pass-through recipes preserve the
  /// source tags.
  var resolvedForCurrentSDRPipeline: VideoColorInfo {
    isHDR ? .sdrRec709 : self
  }

  /// Reads the color attachments from a source asset's first video track.
  static func resolve(from asset: AVAsset) async -> VideoColorInfo {
    guard
      let track = try? await asset.loadTracks(withMediaType: .video).first,
      let formats = try? await track.load(.formatDescriptions),
      let format = formats.first
    else {
      return .sdrRec709
    }

    func formatExtension(_ key: CFString) -> String? {
      CMFormatDescriptionGetExtension(format, extensionKey: key) as? String
    }

    let transfer = formatExtension(kCMFormatDescriptionExtension_TransferFunction)
    let isHDR =
      transfer == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String)
      || transfer == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String)

    return VideoColorInfo(
      colorPrimaries: formatExtension(kCMFormatDescriptionExtension_ColorPrimaries),
      transferFunction: transfer,
      yCbCrMatrix: formatExtension(kCMFormatDescriptionExtension_YCbCrMatrix),
      isHDR: isHDR
    )
  }

  /// Tags the composition's output color.
  ///
  /// Callers pass the already resolved output rather than the source metadata.
  /// This distinction matters for a LUT that consumes Apple Log or another
  /// source space but emits display-referred Rec.709.
  func apply(to composition: AVMutableVideoComposition) {
    composition.colorPrimaries =
      colorPrimaries ?? AVVideoColorPrimaries_ITU_R_709_2
    composition.colorTransferFunction =
      transferFunction ?? AVVideoTransferFunction_ITU_R_709_2
    composition.colorYCbCrMatrix =
      yCbCrMatrix ?? AVVideoYCbCrMatrix_ITU_R_709_2
  }

  /// The concrete color-property dictionary shared by reader and writer.
  ///
  /// Keeping both media endpoints on the same resolved output contract avoids
  /// an untagged intermediate sample being interpreted in a source color space
  /// after the LUT has already produced Rec.709 pixels.
  var avVideoColorProperties: [String: String] {
    [
      AVVideoColorPrimariesKey:
        colorPrimaries ?? AVVideoColorPrimaries_ITU_R_709_2,
      AVVideoTransferFunctionKey:
        transferFunction ?? AVVideoTransferFunction_ITU_R_709_2,
      AVVideoYCbCrMatrixKey:
        yCbCrMatrix ?? AVVideoYCbCrMatrix_ITU_R_709_2,
    ]
  }
}
