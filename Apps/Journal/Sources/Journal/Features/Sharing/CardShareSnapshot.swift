import Foundation
import JournalModel

/// A detached, share-ready copy of one persisted `Card`.
///
/// Sharing should not hold a live SwiftData model while rendering images or
/// videos. This snapshot reads the card once, resolves its primary attachment,
/// and carries only value data into the export layer.
struct CardShareSnapshot: Identifiable, Sendable, Equatable {

  /// Stable card identity, reused for temporary export file names.
  var id: UUID

  /// The persisted card modality that determines how `content` should render.
  var kind: Card.Kind

  /// User-facing creation date shown on exported cards.
  var createdAt: Date

  /// Optional card title, trimmed for display.
  var title: String

  /// Value payload used by image and video exporters.
  var content: CardShareContent

  /// Coordinate attached to the card, when the user opted in.
  var location: Coordinate?

  /// Builds a snapshot from a SwiftData `Card`.
  ///
  /// Media files are read from `JournalStore`'s app-group media directory when
  /// present. Missing files degrade to mirrored thumbnails instead of failing,
  /// because sharing should still work for partially available CloudKit rows.
  @MainActor
  init(card: Card) {
    let title = card.title.trimmingCharacters(in: .whitespacesAndNewlines)
    let body = card.body.trimmingCharacters(in: .whitespacesAndNewlines)
    let attachments = (card.attachments ?? []).sorted { $0.createdAt < $1.createdAt }

    self.id = card.id
    self.kind = card.kind
    self.createdAt = card.createdAt
    self.title = title
    self.location = card.location
    self.content = Self.makeContent(kind: card.kind, body: body, attachments: attachments)
  }

  private static func makeContent(
    kind: Card.Kind,
    body: String,
    attachments: [Attachment]
  ) -> CardShareContent {
    switch kind {
    case .text:
      return .text(body)
    case .photo:
      let attachment = attachments.first(matching: .photo)
      return .photo(imageData: fileData(for: attachment) ?? attachment?.thumbnail)
    case .audio:
      return .audio(fileURL: fileURL(for: attachments.first(matching: .audio)))
    case .doodle:
      let attachment = attachments.first(matching: .doodle)
      return .doodle(
        drawingData: fileData(for: attachment),
        thumbnailData: attachment?.thumbnail
      )
    case .bauhaus:
      let attachment = attachments.first(matching: .bauhaus)
      return .bauhaus(
        artworkData: fileData(for: attachment),
        thumbnailData: attachment?.thumbnail
      )
    @unknown default:
      return .text(body)
    }
  }

  private static func fileData(for attachment: Attachment?) -> Data? {
    guard let url = fileURL(for: attachment) else { return nil }
    return try? Data(contentsOf: url)
  }

  private static func fileURL(for attachment: Attachment?) -> URL? {
    guard let attachment else { return nil }
    return try? JournalStore.fileURL(for: attachment)
  }
}

/// The mutually-exclusive share payload extracted from a `Card`.
///
/// Doodle carries both the encoded vector drawing and its mirrored thumbnail:
/// the image share can use the thumbnail immediately, while replay video export
/// can decode the vector timeline inside the Doodle-aware exporter.
enum CardShareContent: Sendable, Equatable {
  /// A written note.
  case text(String)

  /// A photo card, preferring full-size media bytes and falling back to the
  /// mirrored thumbnail when the full file is unavailable.
  case photo(imageData: Data?)

  /// An audio card, represented by its media file URL.
  case audio(fileURL: URL?)

  /// A doodle card with optional encoded `DoodleDrawing` JSON and thumbnail
  /// fallback.
  case doodle(drawingData: Data?, thumbnailData: Data?)

  /// A Bauhaus card with optional encoded `BauhausGridArtwork` JSON and thumbnail
  /// fallback.
  case bauhaus(artworkData: Data?, thumbnailData: Data?)
}

private extension Array where Element == Attachment {

  func first(matching kind: Attachment.Kind) -> Attachment? {
    first { $0.kind == kind }
  }
}
