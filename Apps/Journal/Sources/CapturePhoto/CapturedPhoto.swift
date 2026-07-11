#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Native image type used when a captured JPEG is decoded for presentation.
#if canImport(UIKit)
public typealias CapturedPhotoImage = UIImage
#elseif canImport(AppKit)
public typealias CapturedPhotoImage = NSImage
#endif

/// A captured still photo. Stores JPEG bytes (Sendable); the host decides how to
/// persist it. `image` rehydrates the platform-native image on demand.
public struct CapturedPhoto: Sendable, Equatable, Codable {
  public var imageData: Data
  public var pixelSize: CGSize

  public init(imageData: Data, pixelSize: CGSize) {
    self.imageData = imageData
    self.pixelSize = pixelSize
  }

  public var image: CapturedPhotoImage? {
    CapturedPhotoImage(data: imageData)
  }
}
