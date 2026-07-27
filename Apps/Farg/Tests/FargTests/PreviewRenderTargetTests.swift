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
  func editorWindowPointsBecomeBoundedPixelCeiling() throws {
    let target = try #require(
      FargPreviewRenderTarget(
        editorWindowSizeInPoints: CGSize(width: 390.75, height: 844),
        displayScale: 3
      )
    )

    #expect(target.maximumPixelSize == CGSize(width: 1_080, height: 1_080))
  }

  @Test
  func narrowEditorWindowKeepsItsNarrowPixelBound() throws {
    let target = try #require(
      FargPreviewRenderTarget(
        editorWindowSizeInPoints: CGSize(width: 150, height: 700),
        displayScale: 2
      )
    )

    #expect(target.maximumPixelSize == CGSize(width: 300, height: 1_080))
  }

  @Test
  func portraitSourceFitsUniformlyWithoutUpscaling() throws {
    let target = try #require(
      FargPreviewRenderTarget(
        maximumPixelSize: CGSize(width: 468, height: 834)
      )
    )

    let renderSize = try target.resolveRenderSize(
      sourceDisplaySize: CGSize(width: 2_160, height: 3_840)
    )

    #expect(renderSize == CGSize(width: 468, height: 832))
  }

  @Test
  func smallSourceRemainsAtSourceResolution() throws {
    let target = try #require(
      FargPreviewRenderTarget(
        maximumPixelSize: CGSize(width: 1_200, height: 900)
      )
    )

    let renderSize = try target.resolveRenderSize(
      sourceDisplaySize: CGSize(width: 640, height: 360)
    )

    #expect(renderSize == CGSize(width: 640, height: 360))
  }

  @Test
  func invalidTransientEditorWindowIsIgnored() {
    #expect(
      FargPreviewRenderTarget(
        editorWindowSizeInPoints: .zero,
        displayScale: 3
      ) == nil
    )
  }

  @Test
  func purposeKeepsPreviewAndExportSpatialPoliciesSeparate() throws {
    let target = try #require(
      FargPreviewRenderTarget(
        maximumPixelSize: CGSize(width: 832, height: 468)
      )
    )

    #expect(FargVideoRenderPurpose.preview(target).allowsRealtimeFrameDropping)
    #expect(
      FargVideoRenderPurpose.preview(target).motionBlurRenderTarget
        == .fitWithin(target.maximumPixelSize)
    )
    #expect(FargVideoRenderPurpose.export.allowsRealtimeFrameDropping == false)
    #expect(FargVideoRenderPurpose.export.motionBlurRenderTarget == .source)
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
