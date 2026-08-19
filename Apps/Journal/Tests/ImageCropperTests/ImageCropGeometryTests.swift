import CoreGraphics
import Testing

@testable import ImageCropper

struct ImageCropGeometryTests {

  @Test
  func aspectFillStartsWithCenteredSquareFromShortestSourceSide() {
    let cropRect = ImageCropGeometry.cropRect(
      sourcePixelSize: CGSize(width: 400, height: 200),
      zoomScale: 1,
      normalizedOffset: .zero
    )

    #expect(cropRect == CGRect(x: 100, y: 0, width: 200, height: 200))
  }

  @Test
  func zoomReducesTheCenteredSourceCrop() {
    let cropRect = ImageCropGeometry.cropRect(
      sourcePixelSize: CGSize(width: 400, height: 200),
      zoomScale: 2,
      normalizedOffset: .zero
    )

    #expect(cropRect == CGRect(x: 150, y: 50, width: 100, height: 100))
  }

  @Test
  func translationClampsBeforeTheCropCanExposeEmptyPixels() {
    let normalizedOffset = ImageCropGeometry.normalizedOffset(
      afterApplying: CGSize(width: 10_000, height: -10_000),
      viewportLength: 200,
      to: .zero,
      sourcePixelSize: CGSize(width: 400, height: 200),
      zoomScale: 1
    )
    let cropRect = ImageCropGeometry.cropRect(
      sourcePixelSize: CGSize(width: 400, height: 200),
      zoomScale: 1,
      normalizedOffset: normalizedOffset
    )

    #expect(normalizedOffset == CGSize(width: 0.5, height: 0))
    #expect(cropRect == CGRect(x: 0, y: 0, width: 200, height: 200))
  }

  @Test
  func presentationIsIndependentOfTheViewportUsedForEditing() {
    let small = ImageCropGeometry.presentation(
      sourcePixelSize: CGSize(width: 400, height: 200),
      viewportLength: 200,
      committedZoomScale: 2,
      committedNormalizedOffset: CGSize(width: 0.25, height: -0.25),
      transientMagnification: 1,
      transientTranslation: .zero
    )
    let large = ImageCropGeometry.presentation(
      sourcePixelSize: CGSize(width: 400, height: 200),
      viewportLength: 600,
      committedZoomScale: 2,
      committedNormalizedOffset: CGSize(width: 0.25, height: -0.25),
      transientMagnification: 1,
      transientTranslation: .zero
    )

    #expect(large.displayedImageSize.width == small.displayedImageSize.width * 3)
    #expect(large.displayedImageSize.height == small.displayedImageSize.height * 3)
    #expect(large.imageOffset.width == small.imageOffset.width * 3)
    #expect(large.imageOffset.height == small.imageOffset.height * 3)
  }
}
