#if os(macOS)
import AppKit
import SwiftUI

/// Internal native image spelling used by Journal's shared raster boundaries.
typealias UIImage = NSImage

/// Internal native color spelling used by Journal's Core Graphics renderers.
typealias UIColor = NSColor

extension Image {
  init(uiImage: NSImage) {
    self.init(nsImage: uiImage)
  }
}

extension Color {
  init(uiColor: NSColor) {
    self.init(nsColor: uiColor)
  }
}

extension NSImage {
  /// Best-effort backing scale for metadata that stores pixel dimensions.
  var scale: CGFloat {
    guard size.width > 0,
      let pixelsWide = representations.map(\.pixelsWide).max()
    else {
      return 1
    }
    return max(CGFloat(pixelsWide) / size.width, 1)
  }

  /// Core Graphics representation used by the cross-platform video renderer.
  var cgImage: CGImage? {
    var proposedRect = NSRect(origin: .zero, size: size)
    return cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
  }

  func pngData() -> Data? {
    guard let cgImage else { return nil }
    return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
  }

  func jpegData(compressionQuality: CGFloat) -> Data? {
    guard let cgImage else { return nil }
    return NSBitmapImageRep(cgImage: cgImage).representation(
      using: .jpeg,
      properties: [.compressionFactor: compressionQuality]
    )
  }
}

extension NSColor {
  /// Resolves a dynamic AppKit color under an explicit appearance.
  func resolvedColor(with appearance: NSAppearance) -> NSColor {
    var resolved = self
    appearance.performAsCurrentDrawingAppearance {
      resolved = usingColorSpace(.deviceRGB) ?? self
    }
    return resolved
  }
}
#endif
