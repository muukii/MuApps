import MuColor
import SwiftUI

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

/// Renders detached entry snapshots into shareable raster images.
@MainActor
enum EntryShareImageRenderer {

  /// Default export size in pixels.
  ///
  /// The ratio follows Instagram Reels' vertical 9:16 canvas while staying at
  /// the platform-common 1080p width.
  static let defaultPixelSize = CGSize(width: 1080, height: 1920)

  /// Renders a prepared share snapshot into a `UIImage`.
  static func image(
    for snapshot: EntryShareSnapshot,
    palette: Palette = .default,
    colorScheme: ColorScheme = .light,
    pixelSize: CGSize = defaultPixelSize,
    scale: CGFloat = 1
  ) -> UIImage? {
    let renderer = ImageRenderer(
      content: EntryShareImageView(snapshot: snapshot, palette: palette)
        .environment(\.colorScheme, colorScheme)
        .frame(width: pixelSize.width, height: pixelSize.height)
    )
    renderer.scale = max(scale, 1)
    renderer.isOpaque = true
    #if canImport(UIKit)
      return renderer.uiImage
    #else
      return renderer.nsImage
    #endif
  }

  /// Renders the static SwiftUI frame used behind Doodle replay video frames.
  static func doodleVideoBaseImage(
    for snapshot: EntryShareSnapshot,
    palette: Palette = .default,
    colorScheme: ColorScheme = .light,
    pixelSize: CGSize = defaultPixelSize,
    scale: CGFloat = 1
  ) -> UIImage? {
    let renderer = ImageRenderer(
      content: EntryShareDoodleVideoBaseFrameView(snapshot: snapshot, palette: palette)
        .environment(\.colorScheme, colorScheme)
        .frame(width: pixelSize.width, height: pixelSize.height)
    )
    renderer.scale = max(scale, 1)
    renderer.isOpaque = true
    #if canImport(UIKit)
      return renderer.uiImage
    #else
      return renderer.nsImage
    #endif
  }

  /// Renders the static SwiftUI frame used behind Bauhaus replay video frames.
  static func bauhausVideoBaseImage(
    for snapshot: EntryShareSnapshot,
    palette: Palette = .default,
    colorScheme: ColorScheme = .light,
    pixelSize: CGSize = defaultPixelSize,
    scale: CGFloat = 1
  ) -> UIImage? {
    let renderer = ImageRenderer(
      content: EntryShareBauhausVideoBaseFrameView(snapshot: snapshot, palette: palette)
        .environment(\.colorScheme, colorScheme)
        .frame(width: pixelSize.width, height: pixelSize.height)
    )
    renderer.scale = max(scale, 1)
    renderer.isOpaque = true
    #if canImport(UIKit)
      return renderer.uiImage
    #else
      return renderer.nsImage
    #endif
  }

  /// Writes a PNG export for `snapshot` into a temporary file and returns the URL.
  static func pngFile(
    for snapshot: EntryShareSnapshot,
    palette: Palette = .default,
    colorScheme: ColorScheme = .light,
    directory: URL = FileManager.default.temporaryDirectory
  ) throws -> URL {
    guard let data = image(for: snapshot, palette: palette, colorScheme: colorScheme)?.pngData()
    else {
      throw EntryShareImageRendererError.renderingFailed
    }

    let url = directory.appending(path: "Journal-\(snapshot.id.uuidString).png")
    try data.write(to: url, options: [.atomic])
    return url
  }
}

/// Failures produced while creating a share image.
enum EntryShareImageRendererError: Error {
  /// The SwiftUI image renderer did not produce a raster image.
  case renderingFailed
}
