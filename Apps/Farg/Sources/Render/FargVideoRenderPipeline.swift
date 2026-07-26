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
        settings: recipe.motionBlur,
        renderTarget: purpose.motionBlurRenderTarget
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
      colorInfo: colorInfo,
      purpose: purpose
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
    colorInfo: VideoColorInfo,
    purpose: FargVideoRenderPurpose
  ) throws -> PreparedFargVideoRender {
    precondition(recipe.motionBlur.isEnabled == false)
    let parametricRenderer = ParametricVideoRenderer()
    let composition: AVMutableVideoComposition
    switch purpose {
    case .export:
      composition = try parametricRenderer.makeVideoComposition(
        for: asset,
        document: recipe.document,
        renderSizeMode: .source,
        ciContext: ciContext
      )

    case .preview(let target):
      let sourceRenderSize = try Self.sourceRenderSize(for: asset)
      let previewRenderSize = try target.resolveRenderSize(
        sourceDisplaySize: sourceRenderSize
      )
      let renderExtent = CGRect(
        origin: .zero,
        size: previewRenderSize
      )
      let document = recipe.document
      let ciContext = ciContext
      composition = AVMutableVideoComposition(asset: asset) { request in
        do {
          let sourceImage = try Self.makePreviewSourceImage(
            request.sourceImage,
            renderExtent: renderExtent
          )
          let output = try parametricRenderer.makeFrameImage(
            from: sourceImage,
            document: document,
            renderExtent: renderExtent
          )
          request.finish(with: output, context: ciContext)
        } catch {
          request.finish(with: error)
        }
      }
      composition.renderSize = previewRenderSize
    }

    colorInfo.apply(to: composition)
    return PreparedFargVideoRender(
      asset: asset,
      videoComposition: composition
    )
  }

  /// Returns the display-oriented canvas supplied by AVFoundation's Core Image
  /// composition handler.
  ///
  /// This sizing probe intentionally lives in Farg: viewport resolution is an
  /// editor-only operational policy and does not expand Brightroom's public
  /// rendering API.
  private static func sourceRenderSize(for asset: AVAsset) throws -> CGSize {
    let composition = AVMutableVideoComposition(asset: asset) { request in
      request.finish(with: request.sourceImage, context: nil)
    }
    let sourceRenderSize: CGSize
    if composition.renderSize.isFargValidVideoRenderSize {
      sourceRenderSize = composition.renderSize
    } else if let compositionAsset = asset as? AVComposition,
      compositionAsset.naturalSize.isFargValidVideoRenderSize
    {
      sourceRenderSize = compositionAsset.naturalSize
    } else {
      sourceRenderSize = composition.renderSize
    }
    guard sourceRenderSize.isFargValidVideoRenderSize else {
      throw ParametricVideoRendererError.invalidSourceRenderSize(
        sourceRenderSize
      )
    }
    return sourceRenderSize
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

extension CGSize {

  fileprivate nonisolated var isFargValidVideoRenderSize: Bool {
    width.isFinite
      && height.isFinite
      && width > 0
      && height > 0
  }
}
