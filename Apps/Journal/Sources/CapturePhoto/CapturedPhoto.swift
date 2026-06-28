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
}
