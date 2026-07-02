import JournalModel
import MuColor
import SwiftUI
import UIKit

/// Renders persisted cards into shareable raster images.
///
/// Callers can pass a live `Card` directly; the renderer snapshots it first and
/// then renders from value data, so the actual image work is decoupled from
/// SwiftData observation.
@MainActor
enum CardShareImageRenderer {

  /// Default export size in pixels.
  ///
  /// The ratio follows Instagram Reels' vertical 9:16 canvas while staying at
  /// the platform-common 1080p width.
  static let defaultPixelSize = CGSize(width: 1080, height: 1920)

  /// Renders a `Card` into a `UIImage`.
  static func image(
    for card: Card,
    palette: Palette = .default,
    colorScheme: ColorScheme = .light,
    pixelSize: CGSize = defaultPixelSize,
    scale: CGFloat = 1
  ) -> UIImage? {
    image(
      for: CardShareSnapshot(card: card),
      palette: palette,
      colorScheme: colorScheme,
      pixelSize: pixelSize,
      scale: scale
    )
  }

  /// Renders a prepared share snapshot into a `UIImage`.
  static func image(
    for snapshot: CardShareSnapshot,
    palette: Palette = .default,
    colorScheme: ColorScheme = .light,
    pixelSize: CGSize = defaultPixelSize,
    scale: CGFloat = 1
  ) -> UIImage? {
    let renderer = ImageRenderer(
      content: CardShareImageView(snapshot: snapshot, palette: palette)
        .environment(\.colorScheme, colorScheme)
        .frame(width: pixelSize.width, height: pixelSize.height)
    )
    renderer.scale = max(scale, 1)
    renderer.isOpaque = true
    return renderer.uiImage
  }

  /// Renders the static SwiftUI frame used behind Doodle replay video frames.
  static func doodleVideoBaseImage(
    for snapshot: CardShareSnapshot,
    palette: Palette = .default,
    colorScheme: ColorScheme = .light,
    pixelSize: CGSize = defaultPixelSize,
    scale: CGFloat = 1
  ) -> UIImage? {
    let renderer = ImageRenderer(
      content: CardShareDoodleVideoBaseFrameView(snapshot: snapshot, palette: palette)
        .environment(\.colorScheme, colorScheme)
        .frame(width: pixelSize.width, height: pixelSize.height)
    )
    renderer.scale = max(scale, 1)
    renderer.isOpaque = true
    return renderer.uiImage
  }

  /// Renders the static SwiftUI frame used behind Bauhaus replay video frames.
  static func bauhausVideoBaseImage(
    for snapshot: CardShareSnapshot,
    palette: Palette = .default,
    colorScheme: ColorScheme = .light,
    pixelSize: CGSize = defaultPixelSize,
    scale: CGFloat = 1
  ) -> UIImage? {
    let renderer = ImageRenderer(
      content: CardShareBauhausVideoBaseFrameView(snapshot: snapshot, palette: palette)
        .environment(\.colorScheme, colorScheme)
        .frame(width: pixelSize.width, height: pixelSize.height)
    )
    renderer.scale = max(scale, 1)
    renderer.isOpaque = true
    return renderer.uiImage
  }

  /// Writes a PNG export for `card` into a temporary file and returns the URL.
  static func pngFile(
    for card: Card,
    palette: Palette = .default,
    colorScheme: ColorScheme = .light,
    directory: URL = FileManager.default.temporaryDirectory
  ) throws -> URL {
    try pngFile(
      for: CardShareSnapshot(card: card),
      palette: palette,
      colorScheme: colorScheme,
      directory: directory
    )
  }

  /// Writes a PNG export for `snapshot` into a temporary file and returns the URL.
  static func pngFile(
    for snapshot: CardShareSnapshot,
    palette: Palette = .default,
    colorScheme: ColorScheme = .light,
    directory: URL = FileManager.default.temporaryDirectory
  ) throws -> URL {
    guard let data = image(for: snapshot, palette: palette, colorScheme: colorScheme)?.pngData() else {
      throw CardShareImageRendererError.renderingFailed
    }

    let url = directory.appending(path: "Journal-\(snapshot.id.uuidString).png")
    try data.write(to: url, options: [.atomic])
    return url
  }
}

/// Failures produced while creating a share image.
enum CardShareImageRendererError: Error {
  /// The SwiftUI image renderer did not produce a raster image.
  case renderingFailed
}
