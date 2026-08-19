import CoreGraphics

/// The display values needed to render one frame of the crop editor.
///
/// This type stays internal so Tinycurve does not depend on the pan and zoom
/// representation used by the current editor implementation.
struct ImageCropPresentation: Equatable {
  let displayedImageSize: CGSize
  let imageOffset: CGSize
  let zoomScale: CGFloat
}

/// Pure crop geometry shared by the interactive editor and JPEG renderer.
enum ImageCropGeometry {

  static func presentation(
    sourcePixelSize: CGSize,
    viewportLength: CGFloat,
    committedZoomScale: CGFloat,
    committedNormalizedOffset: CGSize,
    transientMagnification: CGFloat,
    transientTranslation: CGSize
  ) -> ImageCropPresentation {
    guard sourcePixelSize.isValidImageSize, viewportLength > 0 else {
      return ImageCropPresentation(
        displayedImageSize: .zero,
        imageOffset: .zero,
        zoomScale: 1
      )
    }

    let zoomScale = max(committedZoomScale * transientMagnification, 1)
    let proposedOffset = CGSize(
      width: committedNormalizedOffset.width
        + transientTranslation.width / viewportLength,
      height: committedNormalizedOffset.height
        + transientTranslation.height / viewportLength
    )
    let normalizedOffset = clampedNormalizedOffset(
      proposedOffset,
      sourcePixelSize: sourcePixelSize,
      zoomScale: zoomScale
    )
    let shortestSourceSide = min(sourcePixelSize.width, sourcePixelSize.height)

    // At zoom 1, aspect-fill maps the source's shortest side to the viewport.
    // Keeping the rest of the math normalized to the viewport makes the crop
    // independent of the iPhone, iPad, or Mac window size used for editing.
    let displayScale = viewportLength * zoomScale / shortestSourceSide

    return ImageCropPresentation(
      displayedImageSize: CGSize(
        width: sourcePixelSize.width * displayScale,
        height: sourcePixelSize.height * displayScale
      ),
      imageOffset: CGSize(
        width: normalizedOffset.width * viewportLength,
        height: normalizedOffset.height * viewportLength
      ),
      zoomScale: zoomScale
    )
  }

  static func normalizedOffset(
    afterApplying translation: CGSize,
    viewportLength: CGFloat,
    to committedOffset: CGSize,
    sourcePixelSize: CGSize,
    zoomScale: CGFloat
  ) -> CGSize {
    guard viewportLength > 0 else { return committedOffset }

    let proposedOffset = CGSize(
      width: committedOffset.width + translation.width / viewportLength,
      height: committedOffset.height + translation.height / viewportLength
    )
    return clampedNormalizedOffset(
      proposedOffset,
      sourcePixelSize: sourcePixelSize,
      zoomScale: zoomScale
    )
  }

  static func clampedNormalizedOffset(
    _ offset: CGSize,
    sourcePixelSize: CGSize,
    zoomScale: CGFloat
  ) -> CGSize {
    guard sourcePixelSize.isValidImageSize else { return .zero }

    let zoomScale = max(zoomScale, 1)
    let shortestSourceSide = min(sourcePixelSize.width, sourcePixelSize.height)
    let displayedWidth = sourcePixelSize.width / shortestSourceSide * zoomScale
    let displayedHeight = sourcePixelSize.height / shortestSourceSide * zoomScale
    let maximumOffset = CGSize(
      width: max((displayedWidth - 1) / 2, 0),
      height: max((displayedHeight - 1) / 2, 0)
    )

    return CGSize(
      width: offset.width.clamped(to: -maximumOffset.width...maximumOffset.width),
      height: offset.height.clamped(to: -maximumOffset.height...maximumOffset.height)
    )
  }

  static func cropRect(
    sourcePixelSize: CGSize,
    zoomScale: CGFloat,
    normalizedOffset: CGSize
  ) -> CGRect {
    guard sourcePixelSize.isValidImageSize else { return .null }

    let zoomScale = max(zoomScale, 1)
    let shortestSourceSide = min(sourcePixelSize.width, sourcePixelSize.height)
    let cropLength = shortestSourceSide / zoomScale
    let offset = clampedNormalizedOffset(
      normalizedOffset,
      sourcePixelSize: sourcePixelSize,
      zoomScale: zoomScale
    )

    // A positive visual offset moves the image right/down, exposing pixels from
    // the source's left/top. Converting that movement back into source pixels
    // therefore subtracts it from the centered crop origin.
    let sourcePixelsPerNormalizedPoint = shortestSourceSide / zoomScale
    let centeredOrigin = CGPoint(
      x: (sourcePixelSize.width - cropLength) / 2,
      y: (sourcePixelSize.height - cropLength) / 2
    )
    let maximumOrigin = CGPoint(
      x: sourcePixelSize.width - cropLength,
      y: sourcePixelSize.height - cropLength
    )

    return CGRect(
      x: (centeredOrigin.x - offset.width * sourcePixelsPerNormalizedPoint)
        .clamped(to: 0...maximumOrigin.x),
      y: (centeredOrigin.y - offset.height * sourcePixelsPerNormalizedPoint)
        .clamped(to: 0...maximumOrigin.y),
      width: cropLength,
      height: cropLength
    )
  }
}

extension CGSize {
  fileprivate var isValidImageSize: Bool {
    width.isFinite && height.isFinite && width > 0 && height > 0
  }
}

extension Comparable {
  fileprivate func clamped(to range: ClosedRange<Self>) -> Self {
    min(max(self, range.lowerBound), range.upperBound)
  }
}
