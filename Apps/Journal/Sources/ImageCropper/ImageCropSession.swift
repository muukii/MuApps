import CoreGraphics
import Foundation
import ImageIO
import Observation

/// Errors that can occur while preparing or rendering an image crop.
public enum ImageCropError: Error, Equatable {
  /// The input bytes did not contain a raster image that Image I/O could read.
  case unreadableImage

  /// The selected image did not have usable positive pixel dimensions.
  case invalidImageDimensions

  /// Core Graphics could not create the requested square raster.
  case outputRenderingFailed

  /// Image I/O could not encode the rendered raster as JPEG.
  case jpegEncodingFailed
}

/// Owns one image-cropping edit and produces Tinycurve's avatar payload.
///
/// This concrete type is the app-owned façade for the editor. Callers provide
/// image data and receive a neutral JPEG result; pan/zoom state and rendering
/// implementation details stay private to this module. A future
/// Brightroom-backed editor can therefore replace the internals without
/// exposing Brightroom types to Tinycurve's profile feature.
///
/// The initial implementation intentionally does not rotate the image or apply
/// EXIF orientation metadata. The preview and output both use the encoded pixel
/// raster as-is, so adding orientation support later remains one explicit
/// behavior change rather than an implicit import side effect.
@MainActor
@Observable
public final class ImageCropSession {

  /// Pixel length of each side of the square profile image output.
  public static let outputPixelLength = 512

  private static let maximumWorkingPixelLength = 4_096
  private static let maximumZoomScale: CGFloat = 8

  @ObservationIgnored let sourceImage: CGImage
  @ObservationIgnored let sourcePixelSize: CGSize

  private var zoomScale: CGFloat = 1
  private var normalizedOffset: CGSize = .zero

  /// Creates a crop session from encoded image bytes.
  ///
  /// Large inputs are decoded to a working raster whose longest side is at most
  /// 4096 pixels. This retains ample detail for typical profile photos while
  /// bounding interactive memory use across iPhone, iPad, and Mac.
  public init(imageData: Data) throws {
    guard let imageSource = CGImageSourceCreateWithData(imageData as CFData, nil) else {
      throw ImageCropError.unreadableImage
    }

    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      // Deliberately false: this first version does not normalize EXIF
      // orientation. See the type-level contract above.
      kCGImageSourceCreateThumbnailWithTransform: false,
      kCGImageSourceThumbnailMaxPixelSize: Self.maximumWorkingPixelLength,
      kCGImageSourceShouldCacheImmediately: true,
    ]
    guard
      let sourceImage = CGImageSourceCreateThumbnailAtIndex(
        imageSource,
        0,
        options as CFDictionary
      )
    else {
      throw ImageCropError.unreadableImage
    }

    let sourcePixelSize = CGSize(
      width: sourceImage.width,
      height: sourceImage.height
    )
    guard sourcePixelSize.width > 0, sourcePixelSize.height > 0 else {
      throw ImageCropError.invalidImageDimensions
    }

    self.sourceImage = sourceImage
    self.sourcePixelSize = sourcePixelSize
  }

  /// Renders the current crop as a square JPEG.
  ///
  /// - Parameters:
  ///   - pixelLength: Pixel width and height of the output. The default is the
  ///     512-pixel profile-image contract used by Tinycurve.
  ///   - quality: JPEG compression quality. Values outside `0...1` are clamped.
  /// - Returns: Encoded JPEG bytes with equal pixel width and height.
  public func renderJPEG(
    pixelLength: Int = ImageCropSession.outputPixelLength,
    quality: Double = 0.9
  ) throws -> Data {
    let cropRect = ImageCropGeometry.cropRect(
      sourcePixelSize: sourcePixelSize,
      zoomScale: zoomScale,
      normalizedOffset: normalizedOffset
    )
    return try ImageCropRenderer.makeJPEG(
      from: sourceImage,
      cropRect: cropRect,
      outputPixelLength: pixelLength,
      compressionQuality: quality
    )
  }

  func presentation(
    viewportLength: CGFloat,
    transientMagnification: CGFloat,
    transientTranslation: CGSize
  ) -> ImageCropPresentation {
    let displayedZoomScale = (zoomScale * transientMagnification).clamped(
      to: 1...Self.maximumZoomScale
    )
    return ImageCropGeometry.presentation(
      sourcePixelSize: sourcePixelSize,
      viewportLength: viewportLength,
      committedZoomScale: zoomScale,
      committedNormalizedOffset: normalizedOffset,
      transientMagnification: displayedZoomScale / zoomScale,
      transientTranslation: transientTranslation
    )
  }

  func commitTranslation(_ translation: CGSize, viewportLength: CGFloat) {
    normalizedOffset = ImageCropGeometry.normalizedOffset(
      afterApplying: translation,
      viewportLength: viewportLength,
      to: normalizedOffset,
      sourcePixelSize: sourcePixelSize,
      zoomScale: zoomScale
    )
  }

  func commitMagnification(_ magnification: CGFloat) {
    zoomScale = (zoomScale * magnification).clamped(
      to: 1...Self.maximumZoomScale
    )
    normalizedOffset = ImageCropGeometry.clampedNormalizedOffset(
      normalizedOffset,
      sourcePixelSize: sourcePixelSize,
      zoomScale: zoomScale
    )
  }

  func adjustZoom(by magnification: CGFloat) {
    commitMagnification(magnification)
  }

  var currentZoomScale: CGFloat {
    zoomScale
  }
}

extension Comparable {
  fileprivate func clamped(to range: ClosedRange<Self>) -> Self {
    min(max(self, range.lowerBound), range.upperBound)
  }
}
