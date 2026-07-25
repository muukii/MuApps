//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import AVFoundation
import BrightroomParametric
import CoreImage
import FargMotionBlur
import Foundation

/// One immutable video-render recipe shared by preview and export.
///
/// The Brightroom document remains a single-frame feature graph. Temporal
/// settings live beside it because they require decoded frame neighbors rather
/// than another `ImageEffectFeatureType`.
nonisolated struct FargVideoRenderRecipe: Sendable {
  let document: EditingDocument
  let motionBlur: MotionBlurSettings
}

/// The asset/composition pair a player or asset reader must use together.
nonisolated struct PreparedFargVideoRender: @unchecked Sendable {
  let asset: AVAsset
  let videoComposition: AVMutableVideoComposition
}

/// Controls operational backpressure without changing the authored recipe.
nonisolated enum FargVideoRenderPurpose: Sendable {
  /// Realtime playback keeps only the newest queued Optical Flow frame.
  case preview
  /// Export completes every requested frame.
  case export

  var allowsRealtimeFrameDropping: Bool {
    switch self {
    case .preview:
      return true
    case .export:
      return false
    }
  }
}

/// Prepares the exact rendering path used by both the editor and exporter.
///
/// Motion blur runs before the parametric document to model an in-camera
/// exposure before the selected LUT changes the image's color response.
nonisolated struct FargVideoRenderPipeline: Sendable {

  var ciContext: CIContext = FargCIContext.shared

  func prepare(
    asset: AVAsset,
    recipe: FargVideoRenderRecipe,
    colorInfo: VideoColorInfo,
    purpose: FargVideoRenderPurpose
  ) async throws -> PreparedFargVideoRender {
    let parametricRenderer = ParametricVideoRenderer()

    if recipe.motionBlur.isEnabled {
      let prepared = try await MotionBlurVideoCompositionBuilder(
        quality: .normal,
        ciContext: ciContext,
        allowsRealtimeFrameDropping: purpose.allowsRealtimeFrameDropping
      )
      .prepare(
        asset: asset,
        settings: recipe.motionBlur
      ) { image, renderExtent in
        try parametricRenderer.makeFrameImage(
          from: image,
          document: recipe.document,
          renderExtent: renderExtent
        )
      }
      colorInfo.apply(to: prepared.videoComposition)
      return PreparedFargVideoRender(
        asset: prepared.asset,
        videoComposition: prepared.videoComposition
      )
    }

    return try prepareSingleFrame(
      asset: asset,
      recipe: recipe,
      colorInfo: colorInfo
    )
  }

  /// Prepares the ordinary single-frame path synchronously.
  ///
  /// The editor uses this entry point for LUT slider changes so the current
  /// source-backed player item can update in place without an asynchronous
  /// preparing-state flash.
  func prepareSingleFrame(
    asset: AVAsset,
    recipe: FargVideoRenderRecipe,
    colorInfo: VideoColorInfo
  ) throws -> PreparedFargVideoRender {
    precondition(recipe.motionBlur.isEnabled == false)
    let parametricRenderer = ParametricVideoRenderer()
    let composition = try parametricRenderer.makeVideoComposition(
      for: asset,
      document: recipe.document,
      renderSizeMode: .source,
      ciContext: ciContext
    )
    colorInfo.apply(to: composition)
    return PreparedFargVideoRender(
      asset: asset,
      videoComposition: composition
    )
  }
}
