//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import CoreGraphics
import CoreImage
import Foundation

/// A shared `CIContext` configured to match Brightroom's still export path
/// (extended-linear Display-P3 working space, half-float working format) so the
/// video preview and export render colors consistently with the rest of
/// Brightroom.
nonisolated enum BrightroomVideoCIContext {

  static let shared: CIContext = make()

  private static func make() -> CIContext {
    let workingColorSpace =
      CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
      ?? CGColorSpaceCreateDeviceRGB()

    return CIContext(options: [
      .workingFormat: CIFormat.RGBAh,
      .workingColorSpace: workingColorSpace,
      .highQualityDownsample: true,
      .cacheIntermediates: false,
    ])
  }
}
