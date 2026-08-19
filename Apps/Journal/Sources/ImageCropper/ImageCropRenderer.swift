import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ImageCropRenderer {

  static func makeJPEG(
    from sourceImage: CGImage,
    cropRect: CGRect,
    outputPixelLength: Int,
    compressionQuality: Double
  ) throws -> Data {
    guard outputPixelLength > 0 else {
      throw ImageCropError.outputRenderingFailed
    }

    let integralCropRect = squareIntegralCropRect(
      cropRect,
      sourcePixelSize: CGSize(width: sourceImage.width, height: sourceImage.height)
    )
    guard integralCropRect.isNull == false,
      let croppedImage = sourceImage.cropping(to: integralCropRect)
    else {
      throw ImageCropError.outputRenderingFailed
    }

    let colorSpace =
      CGColorSpace(name: CGColorSpace.sRGB)
      ?? CGColorSpaceCreateDeviceRGB()
    let bitmapInfo =
      CGBitmapInfo.byteOrder32Big.rawValue
      | CGImageAlphaInfo.premultipliedLast.rawValue
    guard
      let context = CGContext(
        data: nil,
        width: outputPixelLength,
        height: outputPixelLength,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: bitmapInfo
      )
    else {
      throw ImageCropError.outputRenderingFailed
    }

    let outputRect = CGRect(
      x: 0,
      y: 0,
      width: outputPixelLength,
      height: outputPixelLength
    )
    // JPEG cannot represent alpha. White makes a transparent source predictable
    // instead of allowing its RGB underlay to become an arbitrary dark fringe.
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(outputRect)
    context.interpolationQuality = .high
    context.draw(croppedImage, in: outputRect)

    guard let renderedImage = context.makeImage() else {
      throw ImageCropError.outputRenderingFailed
    }

    let outputData = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        outputData,
        UTType.jpeg.identifier as CFString,
        1,
        nil
      )
    else {
      throw ImageCropError.jpegEncodingFailed
    }

    let properties: [CFString: Any] = [
      kCGImageDestinationLossyCompressionQuality:
        compressionQuality.clamped(to: 0...1)
    ]
    CGImageDestinationAddImage(destination, renderedImage, properties as CFDictionary)

    guard CGImageDestinationFinalize(destination) else {
      throw ImageCropError.jpegEncodingFailed
    }

    return outputData as Data
  }

  private static func squareIntegralCropRect(
    _ cropRect: CGRect,
    sourcePixelSize: CGSize
  ) -> CGRect {
    guard cropRect.isNull == false,
      cropRect.width.isFinite,
      cropRect.height.isFinite,
      sourcePixelSize.width > 0,
      sourcePixelSize.height > 0
    else {
      return .null
    }

    // `CGImage.cropping(to:)` ultimately selects whole pixels. Rounding one
    // square around the intended center avoids a one-pixel width/height mismatch
    // that could otherwise stretch the final avatar.
    let maximumSide = floor(min(sourcePixelSize.width, sourcePixelSize.height))
    let side = min(max(floor(min(cropRect.width, cropRect.height)), 1), maximumSide)
    let maximumX = sourcePixelSize.width - side
    let maximumY = sourcePixelSize.height - side
    let originX = floor(cropRect.midX - side / 2).clamped(to: 0...maximumX)
    let originY = floor(cropRect.midY - side / 2).clamped(to: 0...maximumY)

    return CGRect(x: originX, y: originY, width: side, height: side)
  }
}

extension Comparable {
  fileprivate func clamped(to range: ClosedRange<Self>) -> Self {
    min(max(self, range.lowerBound), range.upperBound)
  }
}
