import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Creates small raster derivatives for large media files.
///
/// The generator is intended for save-time processing. UI code should keep
/// rendering authored values directly when the authored value is already small
/// or vector based, such as Doodle and Bauhaus documents.
public enum MediaThumbnailGenerator {

  /// Creates a JPEG thumbnail for still-image bytes using Image I/O downsampling.
  ///
  /// Image I/O applies the source orientation transform before returning the
  /// thumbnail. The destination encoder receives the thumbnail `CGImage`
  /// directly, so embedded color space information is preserved when Image I/O
  /// can carry it into the JPEG output.
  public static func imageThumbnail(
    from data: Data,
    options: MediaImageThumbnailOptions = .init()
  ) throws -> MediaThumbnail {
    guard options.maximumPixelLength > 0 else {
      throw MediaThumbnailError.invalidMaximumPixelLength
    }

    let sourceOptions: [CFString: Any] = [
      kCGImageSourceShouldCache: false,
    ]
    guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else {
      throw MediaThumbnailError.imageSourceCreationFailed
    }

    let thumbnailOptions: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCache: false,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: options.maximumPixelLength,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
      throw MediaThumbnailError.thumbnailCreationFailed
    }

    return try jpegThumbnail(from: image, compressionQuality: options.compressionQuality)
  }

  /// Creates a JPEG poster frame for a video file.
  ///
  /// The first frame is intentionally used for now: Journal needs a stable,
  /// cheap save-time derivative for list/widget rendering, while richer poster
  /// selection can be added later without changing the vault schema.
  public static func videoThumbnail(
    from fileURL: URL,
    options: MediaImageThumbnailOptions = .init()
  ) throws -> MediaThumbnail {
    guard options.maximumPixelLength > 0 else {
      throw MediaThumbnailError.invalidMaximumPixelLength
    }

    let asset = AVURLAsset(url: fileURL)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(
      width: options.maximumPixelLength,
      height: options.maximumPixelLength
    )

    let image = try generator.copyCGImage(
      at: CMTime(seconds: 0, preferredTimescale: 600),
      actualTime: nil
    )

    return try jpegThumbnail(from: image, compressionQuality: options.compressionQuality)
  }

  private static func jpegThumbnail(
    from image: CGImage,
    compressionQuality: Double
  ) throws -> MediaThumbnail {
    let outputData = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
      outputData,
      UTType.jpeg.identifier as CFString,
      1,
      nil
    ) else {
      throw MediaThumbnailError.destinationCreationFailed
    }

    let properties: [CFString: Any] = [
      kCGImageDestinationLossyCompressionQuality: compressionQuality.clamped(to: 0...1),
    ]
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)

    guard CGImageDestinationFinalize(destination) else {
      throw MediaThumbnailError.encodingFailed
    }

    return MediaThumbnail(
      data: outputData as Data,
      pixelSize: CGSize(width: image.width, height: image.height),
      contentTypeIdentifier: UTType.jpeg.identifier,
      colorSpaceName: image.colorSpace?.name.map { $0 as String }
    )
  }
}

/// Options that control save-time thumbnail generation for still images.
public struct MediaImageThumbnailOptions: Sendable, Equatable {

  /// Maximum width or height, in pixels, for the generated thumbnail.
  public var maximumPixelLength: Int

  /// JPEG lossy-compression quality in the range `0...1`.
  public var compressionQuality: Double

  public init(
    maximumPixelLength: Int = 768,
    compressionQuality: Double = 0.82
  ) {
    self.maximumPixelLength = maximumPixelLength
    self.compressionQuality = compressionQuality
  }
}

/// A generated raster thumbnail and metadata useful for diagnostics.
public struct MediaThumbnail: Sendable, Equatable {

  /// Encoded thumbnail bytes.
  public var data: Data

  /// Pixel dimensions of the encoded thumbnail.
  public var pixelSize: CGSize

  /// Uniform Type Identifier of `data`.
  public var contentTypeIdentifier: String

  /// Color space name carried by the thumbnail image, when Image I/O exposes it.
  public var colorSpaceName: String?

  public init(
    data: Data,
    pixelSize: CGSize,
    contentTypeIdentifier: String,
    colorSpaceName: String? = nil
  ) {
    self.data = data
    self.pixelSize = pixelSize
    self.contentTypeIdentifier = contentTypeIdentifier
    self.colorSpaceName = colorSpaceName
  }
}

/// Errors that can occur while creating a media thumbnail.
public enum MediaThumbnailError: Error, Equatable {
  case invalidMaximumPixelLength
  case imageSourceCreationFailed
  case thumbnailCreationFailed
  case destinationCreationFailed
  case encodingFailed
}

private extension Comparable {

  func clamped(to range: ClosedRange<Self>) -> Self {
    min(max(self, range.lowerBound), range.upperBound)
  }
}
