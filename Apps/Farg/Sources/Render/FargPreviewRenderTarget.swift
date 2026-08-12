//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import Foundation

/// The fixed pixel-space ceiling for one live editor preview.
///
/// Preview quality is an operational render policy rather than a property of
/// the current SwiftUI layout. Landscape sources fit within 1920×1080, portrait
/// sources fit within 1080×1920, and square sources fit within 1080×1080.
/// Export remains an independent source-resolution policy.
nonisolated struct FargPreviewRenderTarget: Equatable, Sendable {

  private static let landscapeFullHDSize = CGSize(width: 1_920, height: 1_080)
  private static let portraitFullHDSize = CGSize(width: 1_080, height: 1_920)
  private static let squareFullHDSize = CGSize(width: 1_080, height: 1_080)

  /// The orientation-aware Full HD ceiling for the display-oriented source.
  let maximumPixelSize: CGSize

  /// Resolves a deterministic Full HD ceiling from the source presentation.
  ///
  /// The decision deliberately excludes Editor bounds and display scale so the
  /// same source always receives the same Preview geometry.
  init(sourceDisplaySize: CGSize) throws {
    guard
      sourceDisplaySize.width.isFinite,
      sourceDisplaySize.height.isFinite,
      sourceDisplaySize.width > 0,
      sourceDisplaySize.height > 0
    else {
      throw FargPreviewRenderTargetError.invalidSourceSize(sourceDisplaySize)
    }

    if sourceDisplaySize.width > sourceDisplaySize.height {
      maximumPixelSize = Self.landscapeFullHDSize
    } else if sourceDisplaySize.width < sourceDisplaySize.height {
      maximumPixelSize = Self.portraitFullHDSize
    } else {
      maximumPixelSize = Self.squareFullHDSize
    }
  }

  /// Uniformly fits a source canvas without upscaling it.
  ///
  /// Both dimensions are made even for hardware-backed pixel buffers. Flooring
  /// keeps the resolved preview inside the fixed Full HD ceiling.
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
