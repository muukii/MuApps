//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import Foundation

/// The pixel-space ceiling locked for one live editor preview.
///
/// This value describes the Editor window environment, not an authored edit.
/// It is carried only by `FargVideoRenderPurpose.preview`, so exports cannot
/// accidentally inherit the device viewport resolution. The Editor measures
/// its stable parent content rather than its player surface: effect controls
/// may resize the latter without changing the custom compositor's render size.
nonisolated struct FargPreviewRenderTarget: Equatable, Sendable {

  /// The per-axis cap that bounds Preview's Optical Flow working set.
  ///
  /// A current iPhone editor is expected to display no more than this detail,
  /// while the independent width and height limits retain useful quality in a
  /// narrow window. Source frames are still never upscaled.
  private static let maximumPreviewPixelDimension: CGFloat = 1_080

  /// The largest display-oriented frame the visible preview can consume.
  let maximumPixelSize: CGSize

  /// Converts the Editor's stable window content measurement into a bounded
  /// pixel ceiling.
  ///
  /// This deliberately does not accept the live player surface measurement.
  /// The player may become shorter when a tab changes, but that is a display
  /// concern and must not replace a running custom-compositor render context.
  /// Invalid transient geometry is rejected so a zero-size layout pass never
  /// tears down the last usable preview.
  init?(
    editorWindowSizeInPoints: CGSize,
    displayScale: CGFloat
  ) {
    guard
      editorWindowSizeInPoints.width.isFinite,
      editorWindowSizeInPoints.height.isFinite,
      displayScale.isFinite,
      editorWindowSizeInPoints.width > 0,
      editorWindowSizeInPoints.height > 0,
      displayScale > 0
    else {
      return nil
    }
    let windowPixelSize = CGSize(
      width: floor(editorWindowSizeInPoints.width * displayScale),
      height: floor(editorWindowSizeInPoints.height * displayScale)
    )
    self.init(
      maximumPixelSize: CGSize(
        width: min(
          windowPixelSize.width,
          Self.maximumPreviewPixelDimension
        ),
        height: min(
          windowPixelSize.height,
          Self.maximumPreviewPixelDimension
        )
      )
    )
  }

  /// Creates a target from an already measured pixel ceiling.
  init?(maximumPixelSize: CGSize) {
    let normalizedSize = CGSize(
      width: floor(maximumPixelSize.width),
      height: floor(maximumPixelSize.height)
    )
    guard
      normalizedSize.width.isFinite,
      normalizedSize.height.isFinite,
      normalizedSize.width >= 2,
      normalizedSize.height >= 2
    else {
      return nil
    }
    self.maximumPixelSize = normalizedSize
  }

  /// Uniformly fits a source canvas without upscaling it.
  ///
  /// Both dimensions are made even for hardware-backed pixel buffers. Flooring
  /// keeps the resolved preview inside the measured viewport.
  func resolveRenderSize(sourceDisplaySize: CGSize) throws -> CGSize {
    guard
      sourceDisplaySize.width.isFinite,
      sourceDisplaySize.height.isFinite,
      sourceDisplaySize.width > 0,
      sourceDisplaySize.height > 0
    else {
      throw FargPreviewRenderTargetError.invalidSourceSize(sourceDisplaySize)
    }

    let scale = min(
      1,
      maximumPixelSize.width / sourceDisplaySize.width,
      maximumPixelSize.height / sourceDisplaySize.height
    )
    let resolvedSize = CGSize(
      width: Self.evenFloor(sourceDisplaySize.width * scale),
      height: Self.evenFloor(sourceDisplaySize.height * scale)
    )
    guard
      resolvedSize.width <= maximumPixelSize.width,
      resolvedSize.height <= maximumPixelSize.height
    else {
      throw FargPreviewRenderTargetError.cannotFit(
        source: sourceDisplaySize,
        maximum: maximumPixelSize
      )
    }
    return resolvedSize
  }

  private static func evenFloor(_ value: CGFloat) -> CGFloat {
    max(2, floor(value / 2) * 2)
  }
}

/// Geometry failures raised before a preview composition is created.
nonisolated enum FargPreviewRenderTargetError: LocalizedError, Equatable, Sendable {
  case invalidSourceSize(CGSize)
  case cannotFit(source: CGSize, maximum: CGSize)

  var errorDescription: String? {
    switch self {
    case .invalidSourceSize(let size):
      return "The video has an invalid display size (\(size.width)×\(size.height))."
    case .cannotFit(let source, let maximum):
      return
        "Färg couldn't fit the \(source.width)×\(source.height) video inside "
        + "the \(maximum.width)×\(maximum.height) preview."
    }
  }
}
