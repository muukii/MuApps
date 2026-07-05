import Foundation
import SwiftData

/// A logical media attachment owned by a `Card`.
///
/// Concrete files live in `AttachmentResource` rows under the same vault
/// boundary. Keeping bytes out of the store means rows and files have separate
/// lifecycles: a row can arrive from CloudKit before its `CKAsset` file has
/// been written locally. The sync layer posts `VaultMediaFileChange` when a
/// resource file lands so views can retry loading.
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
  ///
  /// This remains as a denormalized primary-resource summary while media moves
  /// to `AttachmentResource`.
  public var byteSize: Int

  /// Primary resource used by list/detail rendering.
  ///
  /// Every media attachment has a primary resource. Additional resources can
  /// represent paired media such as a Live Photo movie without changing the
  /// attachment's logical identity.
  public var primaryResourceID: UUID

  /// Optional save-time raster derivative for large raster media.
  ///
  /// Photo cards and future video poster frames may use this as a compact
  /// display payload. Authored/vector media such as Doodle and Bauhaus should
  /// keep rendering from their media file instead of storing a lossy image here.
  public var thumbnail: Data?

  public var createdAt: Date

  public init(
    id: UUID = UUID(),
    cardID: UUID,
    kind: Kind = .photo,
    byteSize: Int = 0,
    primaryResourceID: UUID,
    thumbnail: Data? = nil,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.cardID = cardID
    self.kindRawValue = kind.rawValue
    self.byteSize = byteSize
    self.primaryResourceID = primaryResourceID
    self.thumbnail = thumbnail
    self.createdAt = createdAt
  }
}

// MARK: - Kind

extension Attachment {

  /// The capture modality behind an attachment, which determines how its
  /// resources are interpreted (photo → still image, Live Photo → still + paired
  /// movie, video → movie, audio → m4a, doodle / bauhaus → encoded JSON). Raw
  /// values are stable CloudKit payload values.
  public enum Kind: String, Codable, Sendable, CaseIterable, Hashable {
    case photo
    case video
    case livePhoto
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
}
