import UIKit

/// A captured still photo. Stores JPEG bytes (Sendable); the host decides how to
/// persist it. `image` rehydrates a `UIImage` on demand.
public struct CapturedPhoto: Sendable, Equatable, Codable {
  public var imageData: Data
  public var pixelSize: CGSize

  public init(imageData: Data, pixelSize: CGSize) {
    self.imageData = imageData
    self.pixelSize = pixelSize
  }

  public var image: UIImage? {
    UIImage(data: imageData)
  }

  /// Downscales the captured still for small list/widget previews. The original
  /// JPEG remains unchanged in `imageData`; this returns a separate JPEG payload
  /// suitable for lightweight mirrored metadata.
  @MainActor
  public func thumbnailData(maxPixelLength: CGFloat = 512) -> Data? {
    image?.thumbnailJPEGData(maxPixelLength: maxPixelLength)
  }
}

extension UIImage {

  @MainActor
  fileprivate func thumbnailJPEGData(maxPixelLength: CGFloat) -> Data? {
    let longestSide = max(size.width, size.height)
    guard longestSide > 0 else { return nil }

    let scale = min(maxPixelLength / longestSide, 1)
    let targetSize = CGSize(
      width: size.width * scale,
      height: size.height * scale
    )

    let format = UIGraphicsImageRendererFormat()
    format.scale = 1

    return UIGraphicsImageRenderer(size: targetSize, format: format)
      .jpegData(withCompressionQuality: 0.82) { _ in
        draw(in: CGRect(origin: .zero, size: targetSize))
      }
  }
}
