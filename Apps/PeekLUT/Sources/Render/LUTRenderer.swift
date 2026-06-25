import CoreImage
import CoreImage.CIFilterBuiltins
import Metal
import UIKit

final class LUTRenderer: @unchecked Sendable {

  static let shared = LUTRenderer()

  let device: MTLDevice?
  let commandQueue: MTLCommandQueue?
  let context: CIContext
  let workingColorSpace: CGColorSpace

  private init() {
    let device = MTLCreateSystemDefaultDevice()
    self.device = device
    self.commandQueue = device?.makeCommandQueue()
    let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    self.workingColorSpace = cs
    if let device {
      self.context = CIContext(
        mtlDevice: device,
        options: [
          .workingColorSpace: cs,
          .cacheIntermediates: true,
        ]
      )
    } else {
      self.context = CIContext(options: [.workingColorSpace: cs])
    }
  }

  /// Returns the input image with the given LUT applied. If `lut` is nil, returns input untouched.
  func apply(lut: LUT?, to image: CIImage) -> CIImage {
    guard let lut else { return image }
    guard let filter = CIFilter(name: "CIColorCubeWithColorSpace", parameters: [
      "inputCubeDimension": lut.dimension,
      "inputCubeData": lut.cubeData,
      "inputColorSpace": workingColorSpace,
      kCIInputImageKey: image,
    ]) else {
      return image
    }
    return filter.outputImage ?? image
  }

  /// Render a CIImage into a UIImage suitable for thumbnails.
  func renderUIImage(_ image: CIImage, maxPixel: CGFloat) -> UIImage? {
    let extent = image.extent
    guard extent.width > 0, extent.height > 0 else { return nil }
    let scale = min(1, maxPixel / max(extent.width, extent.height))
    let scaled = image.transformed(by: .init(scaleX: scale, y: scale))
    guard let cg = context.createCGImage(
      scaled,
      from: scaled.extent,
      format: .RGBA8,
      colorSpace: workingColorSpace
    ) else { return nil }
    return UIImage(cgImage: cg)
  }
}
