//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import AVFoundation
import BrightroomParametric
import CoreImage
import FargMotionBlur
import Foundation

/// The display-referred color space produced by a LUT supported by Färg.
///
/// A `.cube` file does not carry a standardized input/output color-space
/// declaration. Färg therefore owns this contract separately from Brightroom's
/// color-cube data. The current library accepts only LUTs whose final output is
/// SDR Rec.709; additional cases must be introduced together with matching
/// render and encoder support.
nonisolated enum FargLUTOutputColorSpace: Equatable, Sendable {
  case rec709

  var videoColorInfo: VideoColorInfo {
    switch self {
    case .rec709:
      return .sdrRec709
    }
  }

  /// The mastering space used to interpret the LUT-authored result.
  ///
  /// Keep this separate from the final delivery space so Resolve comparisons
  /// remain grounded in the Rec.709 / Gamma 2.4 mastering intent.
  var lutResultColorSpace: CGColorSpace {
    switch self {
    case .rec709:
      return CGColorSpace(name: CGColorSpace.itur_709)!
    }
  }

  /// The destination space used when final pixels are materialized.
  ///
  /// Core Media's Rec.709 encoding compensates the Gamma 2.4 mastering intent
  /// for Apple's standard 1-1-1 playback while retaining Rec.709 metadata.
  /// Apply this only at the final render destination, never to the LUT input
  /// or to temporal-effect intermediate buffers.
  var coreMediaDeliveryColorSpace: CGColorSpace {
    switch self {
    case .rec709:
      return CGColorSpace(name: CGColorSpace.coreMedia709)!
    }
  }
}

/// One immutable video-render recipe shared by preview and export.
///
/// The Brightroom document owns every ordered single-frame effect, including
/// film grain. Temporal settings live beside it because they require decoded
/// frame neighbors rather than another `ImageEffectFeatureType`.
nonisolated struct FargVideoRenderRecipe: Sendable {
  let document: EditingDocument
  let motionBlur: MotionBlurSettings

  /// The color space produced by the recipe's LUT, or `nil` for pass-through.
  let lutOutputColorSpace: FargLUTOutputColorSpace?

  init(
    document: EditingDocument,
    motionBlur: MotionBlurSettings,
    lutOutputColorSpace: FargLUTOutputColorSpace? = nil
  ) {
    self.document = document
    self.motionBlur = motionBlur
    self.lutOutputColorSpace = lutOutputColorSpace
  }

  /// Resolves concrete output tags without reusing the source as LUT metadata.
  func resolveOutputColorInfo(
    sourceColorInfo: VideoColorInfo
  ) -> VideoColorInfo {
    lutOutputColorSpace?.videoColorInfo
      ?? sourceColorInfo.resolvedForCurrentSDRPipeline
  }
}

/// The asset/composition pair a player or asset reader must use together.
nonisolated struct PreparedFargVideoRender: @unchecked Sendable {
  let asset: AVAsset
  let videoComposition: AVMutableVideoComposition
  let outputColorInfo: VideoColorInfo
}

/// Controls operational backpressure without changing the authored recipe.
nonisolated enum FargVideoRenderPurpose: Equatable, Sendable {
  /// Realtime playback renders only the pixels consumed by the live viewport.
  case preview(FargPreviewRenderTarget)
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

  var motionBlurRenderTarget: MotionBlurRenderTarget {
    switch self {
    case .preview(let target):
      return .fitWithin(target.maximumPixelSize)
    case .export:
      return .source
    }
  }
}

/// Prepares the exact rendering path used by both the editor and exporter.
///
/// Motion blur runs before the parametric document to model an in-camera
/// exposure before the selected LUT changes the image's color response.
nonisolated struct FargVideoRenderPipeline: Sendable {

  var ciContext: CIContext = FargCIContext.shared

  /// Prepares the stable temporal asset used by one editor Preview source.
  ///
  /// The returned source is independent of viewport size, LUT state, and Motion
  /// Blur controls. Keeping it alive lets Preview replace only its video
  /// composition while preserving the `AVPlayerItem`, decoder, playhead, and
  /// audio clock.
  func prepareTemporalPreviewSource(
    asset: AVAsset
  ) async throws -> PreparedMotionBlurSource {
    try await MotionBlurVideoCompositionBuilder(
      quality: .normal,
      ciContext: ciContext,
      allowsRealtimeFrameDropping: true
    )
    .prepareSource(asset: asset)
  }

  /// Builds one Preview composition over an already prepared temporal source.
  ///
  /// Disabled Motion Blur still uses the temporal source asset, but its
  /// current-frame mode avoids requesting temporal neighbors or starting
  /// VideoToolbox. Enabled mode shares a live strength source, and the
  /// parametric document source lets Exposure and Grain edits update without
  /// replacing the composition or player item.
  func makeTemporalPreview(
    source: PreparedMotionBlurSource,
    recipe: FargVideoRenderRecipe,
    colorInfo: VideoColorInfo,
    target: FargPreviewRenderTarget,
    strengthSource: MotionBlurStrengthSource,
    documentSource: ParametricDocumentSource
  ) throws -> PreparedFargVideoRender {
    strengthSource.update(strength: recipe.motionBlur.strength)
    if recipe.motionBlur.isEnabled == false {
      strengthSource.requestProcessorSessionReset()
    }
    let outputColorInfo = recipe.resolveOutputColorInfo(
      sourceColorInfo: colorInfo
    )

    let mode: MotionBlurRenderingMode =
      recipe.motionBlur.isEnabled
      ? .opticalFlow(strength: strengthSource)
      : .currentFrame
    let composition = try MotionBlurVideoCompositionBuilder(
      quality: .normal,
      ciContext: ciContext,
      allowsRealtimeFrameDropping: true
    )
    .makeVideoComposition(
      source: source,
      mode: mode,
      renderTarget: .fitWithin(target.maximumPixelSize),
      outputColorSpace:
        recipe.lutOutputColorSpace?.coreMediaDeliveryColorSpace,
      postProcessor: Self.makePostProcessor(
        documentSource: documentSource
      )
    )
    outputColorInfo.apply(to: composition)

    return PreparedFargVideoRender(
      asset: source.asset,
      videoComposition: composition,
      outputColorInfo: outputColorInfo
    )
  }

  func prepare(
    asset: AVAsset,
    recipe: FargVideoRenderRecipe,
    colorInfo: VideoColorInfo,
    purpose: FargVideoRenderPurpose
  ) async throws -> PreparedFargVideoRender {
    let outputColorInfo = recipe.resolveOutputColorInfo(
      sourceColorInfo: colorInfo
    )
    let builder = MotionBlurVideoCompositionBuilder(
      quality: .normal,
      ciContext: ciContext,
      allowsRealtimeFrameDropping: purpose.allowsRealtimeFrameDropping
    )
    let source = try await builder.prepareSource(asset: asset)
    let mode: MotionBlurRenderingMode =
      recipe.motionBlur.isEnabled
      ? .opticalFlow(
        strength: MotionBlurStrengthSource(
          strength: recipe.motionBlur.strength
        )
      )
      : .currentFrame
    let composition = try builder.makeVideoComposition(
      source: source,
      mode: mode,
      renderTarget: purpose.motionBlurRenderTarget,
      outputColorSpace:
        recipe.lutOutputColorSpace?.coreMediaDeliveryColorSpace,
      postProcessor: Self.makePostProcessor(
        documentSource: ParametricDocumentSource(document: recipe.document)
      )
    )
    outputColorInfo.apply(to: composition)

    return PreparedFargVideoRender(
      asset: source.asset,
      videoComposition: composition,
      outputColorInfo: outputColorInfo
    )
  }

  /// Builds the shared frame post-processor for the complete parametric document.
  ///
  /// Motion blur has already run before this closure. The document then
  /// evaluates its ordered single-frame features, including LUT followed by
  /// film grain, using the composition time supplied for this frame.
  private static func makePostProcessor(
    documentSource: ParametricDocumentSource
  ) -> MotionBlurVideoCompositionBuilder.PostProcessor {
    let parametricRenderer = ParametricVideoRenderer()
    return { image, renderExtent, compositionTime in
      try parametricRenderer.makeFrameImage(
        from: image,
        document: documentSource.snapshot(),
        renderExtent: renderExtent,
        presentationTime: compositionTime
      )
    }
  }

  /// Normalizes and downsamples AVFoundation's display-oriented frame before
  /// the Brightroom feature graph evaluates it.
  ///
  /// Exact x/y ratios fill the already aspect-fitted even-pixel target and
  /// prevent fractional transparent edges at the composition boundary.
  static func makePreviewSourceImage(
    _ sourceImage: CIImage,
    renderExtent: CGRect
  ) throws -> CIImage {
    let sourceExtent = sourceImage.extent
    guard
      sourceExtent.width.isFinite,
      sourceExtent.height.isFinite,
      sourceExtent.width > 0,
      sourceExtent.height > 0
    else {
      throw ParametricVideoRendererError.invalidSourceRenderSize(
        sourceExtent.size
      )
    }
    let normalizedImage = sourceImage.transformed(
      by: CGAffineTransform(
        translationX: -sourceExtent.minX,
        y: -sourceExtent.minY
      )
    )
    return
      normalizedImage
      .transformed(
        by: CGAffineTransform(
          scaleX: renderExtent.width / sourceExtent.width,
          y: renderExtent.height / sourceExtent.height
        )
      )
      .cropped(to: renderExtent)
  }
}
