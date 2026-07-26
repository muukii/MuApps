import CoreVideo
import Testing

@testable import FargMotionBlur

/// Protects the source-side half of Färg's LUT color contract.
///
/// A video composition's Rec.709 properties also describe its requested source
/// color space. These capabilities ensure AVFoundation may deliver native
/// Apple Log/10-bit YCbCr frames for conversion inside the compositor instead
/// of converting them to Rec.709 before the LUT.
@Suite("Motion Blur color negotiation")
struct MotionBlurColorNegotiationTests {

  @Test
  func compositorPreservesWideAndHDRSourceColor() throws {
    let compositor = MotionBlurVideoCompositor()

    #expect(compositor.supportsWideColorSourceFrames)
    #expect(compositor.supportsHDRSourceFrames)
    #expect(compositor.canConformColorOfSourceFrames)

    let attributes = try #require(
      compositor.sourcePixelBufferAttributes
    )
    let formats = try #require(
      attributes[kCVPixelBufferPixelFormatTypeKey as String] as? [Int]
    )
    #expect(
      formats.contains(
        Int(kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange)
      )
    )
    #expect(
      formats.contains(
        Int(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
      )
    )
    #expect(formats.contains(Int(kCVPixelFormatType_64RGBAHalf)))
  }
}
