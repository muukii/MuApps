import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import ImageCropper

@MainActor
struct ImageCropSessionTests {

  @Test
  func resultIsSquare512PixelJPEG() throws {
    let session = try ImageCropSession(
      imageData: makeJPEG(width: 800, height: 400)
    )

    let jpegData = try session.renderJPEG()
    let imageSource = try #require(
      CGImageSourceCreateWithData(jpegData as CFData, nil)
    )
    let image = try #require(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))

    #expect(image.width == 512)
    #expect(image.height == 512)
  }

  @Test
  func importDoesNotApplyEXIFOrientationMetadata() throws {
    let imageData = try makeJPEG(
      width: 80,
      height: 40,
      orientation: .right
    )

    let session = try ImageCropSession(imageData: imageData)

    #expect(session.sourcePixelSize == CGSize(width: 80, height: 40))
  }

  private func makeJPEG(
    width: Int,
    height: Int,
    orientation: CGImagePropertyOrientation = .up
  ) throws -> Data {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = try #require(
      CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    )
    context.setFillColor(CGColor(red: 0.15, green: 0.45, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())

    let outputData = NSMutableData()
    let destination = try #require(
      CGImageDestinationCreateWithData(
        outputData,
        UTType.jpeg.identifier as CFString,
        1,
        nil
      )
    )
    let properties: [CFString: Any] = [
      kCGImagePropertyOrientation: orientation.rawValue
    ]
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))

    return outputData as Data
  }
}
