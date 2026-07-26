import CoreGraphics
import Foundation
import ImageIO
import Testing
#if canImport(UIKit)
import UIKit
#endif

@testable import CapturePhoto

struct CapturedPhotoJPEGEncoderTests {

  @Test
  func encodedJPEGPreservesEveryImageIOOrientation() throws {
    let sourceImage = try makeSourceImage()
    let orientations: [CGImagePropertyOrientation] = [
      .up,
      .upMirrored,
      .down,
      .downMirrored,
      .left,
      .leftMirrored,
      .right,
      .rightMirrored,
    ]

    for orientation in orientations {
      let photo = try CapturedPhotoJPEGEncoder.encode(
        sourceImage,
        orientation: orientation,
        compressionQuality: 0.9
      )
      let imageSource = try #require(
        CGImageSourceCreateWithData(photo.imageData as CFData, nil)
      )
      let properties = try #require(
        CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil)
          as? [CFString: Any]
      )
      let storedOrientation = try #require(
        properties[kCGImagePropertyOrientation] as? NSNumber
      )

      #expect(storedOrientation.uint32Value == orientation.rawValue)
      #expect(photo.pixelSize == expectedPixelSize(for: orientation))
    }
  }

  @Test
  func imageIODownsamplingAppliesCapturedRotationAndMirroring() throws {
    let sourceImage = try makeSourceImage()
    let photo = try CapturedPhotoJPEGEncoder.encode(
      sourceImage,
      orientation: .rightMirrored,
      compressionQuality: 0.9
    )
    let imageSource = try #require(
      CGImageSourceCreateWithData(photo.imageData as CFData, nil)
    )
    let thumbnailOptions: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: 100,
    ]
    let displayedImage = try #require(
      CGImageSourceCreateThumbnailAtIndex(
        imageSource,
        0,
        thumbnailOptions as CFDictionary
      )
    )

    #expect(displayedImage.width == 20)
    #expect(displayedImage.height == 40)
  }

  #if canImport(UIKit)
  @Test
  func uiImageReadsCapturedFrontCameraOrientation() throws {
    let sourceImage = try makeSourceImage()
    let photo = try CapturedPhotoJPEGEncoder.encode(
      sourceImage,
      orientation: .leftMirrored,
      compressionQuality: 0.9
    )
    let image = try #require(UIImage(data: photo.imageData))

    #expect(image.imageOrientation == .leftMirrored)
    #expect(image.size == CGSize(width: 20, height: 40))
  }
  #endif

  private func makeSourceImage() throws -> CGImage {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = try #require(
      CGContext(
        data: nil,
        width: 40,
        height: 20,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    )
    context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
    return try #require(context.makeImage())
  }

  private func expectedPixelSize(
    for orientation: CGImagePropertyOrientation
  ) -> CGSize {
    switch orientation {
    case .left, .leftMirrored, .right, .rightMirrored:
      return CGSize(width: 20, height: 40)
    case .up, .upMirrored, .down, .downMirrored:
      return CGSize(width: 40, height: 20)
    }
  }
}
