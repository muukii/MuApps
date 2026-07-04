import Foundation
import SwiftData

/// A media file attached to a `Card` — the row is the reference, the bytes live
/// at `media/<id>` inside the vault directory.
///
/// Keeping bytes out of the store means the row and its file share the same
/// vault boundary but separate lifecycles: a row can arrive from CloudKit
/// before its `CKAsset` file has been written locally. The sync layer posts
/// `VaultMediaFileChange` when the file lands so views can retry loading.
///
/// References the owning card by UUID (no SwiftData relationship) for the same
/// record-mapping reasons as `Card`; the delete cascade is a domain rule in
/// `VaultContentStore`.
@Model
public final class Attachment {

  @Attribute(.unique)
  public var id: UUID

  public var cardID: UUID

  /// Raw modality string as stored and synced; see `Card.kindRawValue` for why
  /// this is a string. Read through `kind`.
  public var kindRawValue: String

  /// Size of the on-disk file in bytes, recorded at attach time.
  public var byteSize: Int

  /// Small rasterized preview that rides along in the CloudKit record itself,
  /// so lightweight surfaces can render before the full asset downloads.
  public var thumbnail: Data?

  public var createdAt: Date

  public init(
    id: UUID = UUID(),
    cardID: UUID,
    kind: Kind = .photo,
    byteSize: Int = 0,
    thumbnail: Data? = nil,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.cardID = cardID
    self.kindRawValue = kind.rawValue
    self.byteSize = byteSize
    self.thumbnail = thumbnail
    self.createdAt = createdAt
  }
}

// MARK: - Kind

extension Attachment {

  /// The capture modality behind an attachment, which determines how the bytes
  /// are interpreted (photo → JPEG, audio → m4a, doodle / bauhaus → encoded
  /// JSON). Raw values match the legacy `JournalModel.Attachment.Kind`.
  public enum Kind: String, Codable, Sendable, CaseIterable {
    case photo
    case audio
    case doodle
    case bauhaus

    /// A kind this build does not recognize — synced from a newer app version.
    case unknown
  }

  /// Typed view over `kindRawValue`. Unrecognized raw values read as `.unknown`.
  public var kind: Kind {
    get { Kind(rawValue: kindRawValue) ?? .unknown }
    set { kindRawValue = newValue.rawValue }
  }

  /// File name on disk — just the id, **no extension** (same convention as the
  /// legacy media sync). The record name maps straight to the file; `kind`
  /// already says how to read it.
  public var fileName: String {
    id.uuidString
  }
}
