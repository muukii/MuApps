import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import AppUIComponents

struct ContentMediaDisplayImageDecoderTests {

  @Test
  func dataDecodeCapsLongestEdgeWithoutChangingAspectRatio() throws {
    let data = try makeJPEG(width: 2_048, height: 1_024)

    let image = try #require(
      ContentMediaDisplayImageDecoder.image(from: data)
    )

    #expect(image.width == ContentMediaDisplayImageDecoder.maximumPixelLength)
    #expect(image.height == 512)
  }

  @Test
  func fileDecodeUsesTheSameFixedLimit() throws {
    let data = try makeJPEG(width: 1_024, height: 2_048)
    let fileURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("jpg")
    try data.write(to: fileURL, options: .atomic)
    defer { try? FileManager.default.removeItem(at: fileURL) }

    let image = try #require(
      ContentMediaDisplayImageDecoder.image(at: fileURL)
    )

    #expect(image.width == 512)
    #expect(image.height == ContentMediaDisplayImageDecoder.maximumPixelLength)
  }

  @Test
  func decodeAppliesImageIOOrientationWithoutUpscalingSmallImages() throws {
    let data = try makeJPEG(
      width: 80,
      height: 40,
      orientation: .right
    )

    let image = try #require(
      ContentMediaDisplayImageDecoder.image(from: data)
    )

    #expect(image.width == 40)
    #expect(image.height == 80)
  }

  private func makeJPEG(
    width: Int,
    height: Int,
    orientation: CGImagePropertyOrientation = .up
  ) throws -> Data {
    let context = try #require(
      CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    )
    context.setFillColor(
      CGColor(red: 0.18, green: 0.42, blue: 0.76, alpha: 1)
    )
    context.fill(
      CGRect(x: 0, y: 0, width: width, height: height)
    )
    let sourceImage = try #require(context.makeImage())

    let output = NSMutableData()
    let destination = try #require(
      CGImageDestinationCreateWithData(
        output,
        UTType.jpeg.identifier as CFString,
        1,
        nil
      )
    )
    let properties: [CFString: Any] = [
      kCGImagePropertyOrientation: orientation.rawValue,
      kCGImageDestinationLossyCompressionQuality: 0.9,
    ]
    CGImageDestinationAddImage(
      destination,
      sourceImage,
      properties as CFDictionary
    )
    try #require(CGImageDestinationFinalize(destination))
    return output as Data
  }
}
