import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Encodes one camera raster as a JPEG while preserving its display orientation.
///
/// `AVCapturePhotoOutput` expresses rotation and mirroring through Image I/O
/// orientation metadata. Keeping that metadata with the `CGImage` avoids a
/// full-resolution redraw while still producing bytes that `UIImage`, `NSImage`,
/// and the app's thumbnail generator can present upright.
enum CapturedPhotoJPEGEncoder {

  /// Creates the persisted photo payload for one captured camera raster.
  static func encode(
    _ image: CGImage,
    orientation: CGImagePropertyOrientation,
    compressionQuality: Double
  ) throws -> CapturedPhoto {
    let outputData = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
      outputData,
      UTType.jpeg.identifier as CFString,
      1,
      nil
    ) else {
      throw CapturedPhotoJPEGEncoderError.destinationCreationFailed
    }

    let properties: [CFString: Any] = [
      kCGImageDestinationLossyCompressionQuality:
        compressionQuality.clamped(to: 0...1),
      kCGImagePropertyOrientation: orientation.rawValue,
    ]
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)

    guard CGImageDestinationFinalize(destination) else {
      throw CapturedPhotoJPEGEncoderError.encodingFailed
    }

    return CapturedPhoto(
      imageData: outputData as Data,
      pixelSize: orientation.displayPixelSize(for: image)
    )
  }
}

/// Failures produced while packaging a captured camera raster as JPEG.
enum CapturedPhotoJPEGEncoderError: Error {
  /// Image I/O could not allocate a JPEG destination.
  case destinationCreationFailed
  /// Image I/O could not finalize the encoded JPEG bytes.
  case encodingFailed
}

extension CGImagePropertyOrientation {

  /// Returns the pixel dimensions after applying this display orientation.
  fileprivate func displayPixelSize(for image: CGImage) -> CGSize {
    switch self {
    case .left, .leftMirrored, .right, .rightMirrored:
      return CGSize(width: image.height, height: image.width)
    case .up, .upMirrored, .down, .downMirrored:
      return CGSize(width: image.width, height: image.height)
    }
  }
}

private extension Comparable {

  func clamped(to range: ClosedRange<Self>) -> Self {
    min(max(self, range.lowerBound), range.upperBound)
  }
}
