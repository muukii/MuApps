#if os(macOS)
import AppKit
import SwiftUI

/// Internal native image spelling used by shared preview code on macOS.
typealias UIImage = NSImage

/// Internal native color spelling used by shared preview code on macOS.
typealias UIColor = NSColor

extension Image {
  /// Keeps shared SwiftUI preview call sites source-compatible while rendering
  /// an AppKit image in the native Mac product.
  init(uiImage: NSImage) {
    self.init(nsImage: uiImage)
  }
}

extension Color {
  /// AppKit counterpart to SwiftUI's UIKit color initializer.
  init(uiColor: NSColor) {
    self.init(nsColor: uiColor)
  }
}
#endif
