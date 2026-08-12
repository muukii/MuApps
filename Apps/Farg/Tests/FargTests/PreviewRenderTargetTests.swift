import BrightroomParametric
import CoreImage
import CoreMedia
import CoreVideo
import FargMotionBlur
import Foundation
import Testing

@testable import Farg

@Suite("Preview render target")
struct PreviewRenderTargetTests {

  @Test
  func landscapeSourceUsesFixedFullHDTarget() throws {
    let sourceSize = CGSize(width: 3_840, height: 2_160)
    let target = try FargPreviewRenderTarget(
      sourceDisplaySize: sourceSize
    )

    #expect(target.maximumPixelSize == CGSize(width: 1_920, height: 1_080))
    #expect(try target.resolveRenderSize(sourceDisplaySize: sourceSize) == target.maximumPixelSize)
  }

  @Test
  func portraitSourceUsesFixedFullHDTarget() throws {
    let sourceSize = CGSize(width: 2_160, height: 3_840)
    let target = try FargPreviewRenderTarget(
      sourceDisplaySize: sourceSize
    )

    #expect(target.maximumPixelSize == CGSize(width: 1_080, height: 1_920))
    #expect(try target.resolveRenderSize(sourceDisplaySize: sourceSize) == target.maximumPixelSize)
  }

  @Test
  func squareSourceUsesSquare1080Target() throws {
    let sourceSize = CGSize(width: 2_160, height: 2_160)
    let target = try FargPreviewRenderTarget(
      sourceDisplaySize: sourceSize
    )

    #expect(target.maximumPixelSize == CGSize(width: 1_080, height: 1_080))
    #expect(try target.resolveRenderSize(sourceDisplaySize: sourceSize) == target.maximumPixelSize)
  }

  @Test
  func smallSourceRemainsAtSourceResolution() throws {
    let sourceSize = CGSize(width: 1_280, height: 720)
    let target = try FargPreviewRenderTarget(
      sourceDisplaySize: sourceSize
    )

    #expect(try target.resolveRenderSize(sourceDisplaySize: sourceSize) == sourceSize)
  }

  @Test
  func nonWidescreenSourcePreservesAspectWithin1080p() throws {
    let sourceSize = CGSize(width: 3_840, height: 2_880)
    let target = try FargPreviewRenderTarget(
      sourceDisplaySize: sourceSize
    )

    #expect(
      try target.resolveRenderSize(sourceDisplaySize: sourceSize)
        == CGSize(width: 1_440, height: 1_080)
    )
  }

  @Test
  func invalidSourceSizeIsRejected() {
    #expect(throws: FargPreviewRenderTargetError.self) {
      try FargPreviewRenderTarget(sourceDisplaySize: .zero)
    }
  }

  @Test
  func purposeKeepsPreviewAndExportSpatialPoliciesSeparate() throws {
    let sourceSize = CGSize(width: 3_840, height: 2_160)
    let previewTarget = try FargVideoRenderPurpose.preview.motionBlurRenderTarget(
      sourceDisplaySize: sourceSize
    )

    #expect(FargVideoRenderPurpose.preview.allowsRealtimeFrameDropping)
    #expect(
      previewTarget == .fitWithin(CGSize(width: 1_920, height: 1_080))
    )
    #expect(FargVideoRenderPurpose.export.allowsRealtimeFrameDropping == false)
    #expect(
      try FargVideoRenderPurpose.export.motionBlurRenderTarget(
        sourceDisplaySize: sourceSize
      ) == .source
    )
  }

  @Test
  func previewPreprocessingNormalizesAndDownsamplesTheFeatureInput() throws {
    let sourceExtent = CGRect(x: 12, y: -8, width: 64, height: 36)
    let sourceImage = CIImage(
      color: CIColor(red: 1, green: 0, blue: 0)
    )
    .cropped(to: sourceExtent)
    let renderExtent = CGRect(x: 0, y: 0, width: 24, height: 12)

    let output = try FargVideoRenderPipeline.makePreviewSourceImage(
      sourceImage,
      renderExtent: renderExtent
    )

    #expect(output.extent == renderExtent)
  }

  @Test
  func previewPreprocessingRejectsAnEmptySourceExtent() {
    #expect(throws: ParametricVideoRendererError.self) {
      try FargVideoRenderPipeline.makePreviewSourceImage(
        .empty(),
        renderExtent: CGRect(x: 0, y: 0, width: 24, height: 12)
      )
    }
  }
}

@Suite("Export frame geometry")
struct ExportFrameGeometryTests {

  @Test
  func matchingSampleFormatDescriptionIsAccepted() throws {
    let formatDescription = try makeFormatDescription(width: 24, height: 18)

    try VideoExportFrameGeometry.validate(
      formatDescription: formatDescription,
      expected: CGSize(width: 24, height: 18)
    )
  }

  @Test
  func sampleFormatMismatchReportsExpectedAndActualDimensions() throws {
    let formatDescription = try makeFormatDescription(width: 24, height: 18)

    do {
      try VideoExportFrameGeometry.validate(
        formatDescription: formatDescription,
        expected: CGSize(width: 18, height: 24)
      )
      Issue.record("A mismatched encoder frame was accepted.")
    } catch let VideoExportError.inconsistentVideoFrameSize(expected, actual) {
      #expect(expected == CGSize(width: 18, height: 24))
      #expect(actual == CGSize(width: 24, height: 18))
    } catch {
      Issue.record("Unexpected geometry error: \(error)")
    }
  }

  private func makeFormatDescription(
    width: Int,
    height: Int
  ) throws -> CMVideoFormatDescription {
    var pixelBuffer: CVPixelBuffer?
    let pixelBufferStatus = CVPixelBufferCreate(
      kCFAllocatorDefault,
      width,
      height,
      kCVPixelFormatType_32BGRA,
      nil,
      &pixelBuffer
    )
    let requiredPixelBuffer = try #require(
      pixelBuffer,
      "CVPixelBufferCreate failed with status \(pixelBufferStatus)."
    )

    var formatDescription: CMVideoFormatDescription?
    let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(
      allocator: kCFAllocatorDefault,
      imageBuffer: requiredPixelBuffer,
      formatDescriptionOut: &formatDescription
    )
    return try #require(
      formatDescription,
      "CMVideoFormatDescriptionCreateForImageBuffer failed with status \(formatStatus)."
    )
  }
}
