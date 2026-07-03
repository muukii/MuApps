import CaptureBauhaus
import CaptureDoodle
import Foundation
import JournalModel
import MuColor
import SwiftData
import SwiftUI

/// Backfills lightweight thumbnails for media rows created before the save path
/// generated them.
///
/// Main entry rendering still decodes the attachment file. This only fills the
/// mirrored `Attachment.thumbnail` field so the widget and share fallbacks can
/// show local media even when they do not load the full file.
enum JournalThumbnailBackfill {

  private static let maximumPixelLength: CGFloat = 512
  private static let bauhausImageSize = CGSize(width: 512, height: 512)

  @MainActor
  static func run(
    in context: ModelContext,
    palette: Palette = .default,
    colorScheme: ColorScheme = .light
  ) throws -> Int {
    let attachments = try context.fetch(FetchDescriptor<Attachment>())
    var updatedCount = 0

    for attachment in attachments where attachment.thumbnail == nil {
      guard let thumbnail = thumbnailData(
        for: attachment,
        palette: palette,
        colorScheme: colorScheme
      ) else {
        continue
      }

      attachment.thumbnail = thumbnail
      updatedCount += 1
    }

    if updatedCount > 0 {
      try context.save()
    }

    return updatedCount
  }

  @MainActor
  private static func thumbnailData(
    for attachment: Attachment,
    palette: Palette,
    colorScheme: ColorScheme
  ) -> Data? {
    guard let data = attachmentData(for: attachment) else {
      return nil
    }

    switch attachment.kind {
    case .doodle:
      guard let drawing = try? JSONDecoder().decode(DoodleDrawing.self, from: data) else {
        return nil
      }
      return drawing
        .image(inkColor: palette.tint, scale: thumbnailScale(for: drawing.canvasSize))
        .flatMap { $0.pngData() }
    case .bauhaus:
      guard let document = try? JSONDecoder().decode(BauhausGridDocument.self, from: data) else {
        return nil
      }
      return document
        .image(colorScheme: colorScheme, size: bauhausImageSize)
        .flatMap { $0.pngData() }
    case .photo, .audio:
      return nil
    @unknown default:
      return nil
    }
  }

  private static func attachmentData(for attachment: Attachment) -> Data? {
    guard
      let url = try? JournalStore.fileURL(for: attachment),
      FileManager.default.fileExists(atPath: url.path)
    else {
      return nil
    }
    return try? Data(contentsOf: url)
  }

  private static func thumbnailScale(for canvasSize: CGSize) -> CGFloat {
    let longestEdge = max(canvasSize.width, canvasSize.height)
    guard longestEdge > maximumPixelLength else { return 1 }
    return maximumPixelLength / longestEdge
  }
}
