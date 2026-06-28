import Foundation
import SwiftData

/// A media file attached to a `Card` — a photo, an ambient-audio recording, a
/// doodle, or Bauhaus grid artwork. The **bytes live as a file on disk** in the
/// shared App Group container
/// (see `JournalStore.mediaDirectory`); this model stores only the metadata that
/// must be queryable plus an optional small `thumbnail` for lightweight fallback
/// surfaces such as widgets and share rendering.
///
/// Why a reference instead of the bytes themselves: keeping large media out of the
/// SwiftData store means CloudKit's automatic mirroring never eagerly uploads or
/// downloads it. The app process syncs the files deliberately through its own
/// CKAsset records, keeping that lifecycle independent from SwiftData's mirrored
/// rows. The trade-off is that the file lifecycle becomes the app's job — see
/// `JournalStore.reconcileOrphanFiles` and the app target's `MediaSyncEngine`.
///
/// CloudKit-mirroring constraints apply as on `Card`: every stored property is
/// optional-or-defaulted, no `.unique`, and the relationship is optional.
@Model
public final class Attachment {

  /// Stable identity, and the basis for the file name on disk (`<id>.<ext>`). As
  /// with `Card.id`, CloudKit can't enforce uniqueness, so dedup is an app concern.
  public var id: UUID = UUID()

  /// Which capture modality produced this — and therefore how the bytes are
  /// interpreted (JPEG / m4a / doodle JSON). Defaulted because CloudKit forbids a
  /// non-optional stored property without a default; `init` always sets the real
  /// value.
  public var kind: Kind = Attachment.Kind.photo

  /// Size of the on-disk file in bytes, recorded at attach time. Cheap to keep and
  /// lets storage / quota display avoid stat-ing every file.
  public var byteSize: Int = 0

  /// A small rasterized preview. Small enough to ride along on CloudKit's automatic
  /// mirroring, so lightweight surfaces can still render when the full file is not
  /// locally available. Journal's main entries UI prefers the local media file and
  /// treats this as a fallback-only field.
  public var thumbnail: Data?

  public var createdAt: Date = Date()

  /// Owning card. The cascade delete rule is declared on `Card.attachments`, so
  /// removing a Card removes its Attachment rows; the *files* are reclaimed
  /// separately by `JournalStore.reconcileOrphanFiles`. Optional per the CloudKit
  /// constraint on mirrored relationships.
  public var card: Card?

  public init(kind: Kind, byteSize: Int = 0, thumbnail: Data? = nil) {
    self.id = UUID()
    self.kind = kind
    self.byteSize = byteSize
    self.thumbnail = thumbnail
    self.createdAt = Date()
  }
}

// MARK: - Kind

extension Attachment {

  /// The capture modality behind an attachment, which determines how the stored
  /// bytes are interpreted (photo → JPEG, audio → m4a, doodle → encoded
  /// `DoodleDrawing` JSON, Bauhaus → encoded `BauhausGridArtwork` JSON).
  public enum Kind: String, Codable, Sendable, CaseIterable {
    case photo
    case audio
    case doodle
    case bauhaus
  }

  /// File name on disk — just the id, **no extension**. Resolved against
  /// `JournalStore.mediaDirectory` to locate the bytes. Keeping it extension-free
  /// lets the media sync engine map a CloudKit record name (also the id) straight
  /// to the file with no lookup; `kind` already says how to read it.
  public var fileName: String {
    id.uuidString
  }
}
