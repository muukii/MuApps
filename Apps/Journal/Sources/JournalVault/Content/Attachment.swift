import Foundation
import SwiftData

/// A logical file-backed attachment owned by a `Card`.
///
/// Concrete files live in `AttachmentResource` rows under the same vault
/// boundary. Keeping bytes out of the store means rows and files have separate
/// lifecycles: a row can arrive from CloudKit before its `CKAsset` file has
/// been written locally. `AttachmentResource.localFileRevision` changes when a
/// resource file lands so views can retry through SwiftData observation.
///
/// The public model connection is the SwiftData `card` relationship. A
/// module-private reference id is kept beside it so CloudKit imports can store
/// an attachment before its card has arrived, then repair the relationship
/// later without exposing sync ordering to app UI.
@Model
public final class Attachment {

  @Attribute(.unique)
  public var id: UUID

  /// Owning card once the local graph has been repaired.
  public var card: Card?

  /// CloudKit import/export and out-of-order repair key for `card`.
  ///
  /// This is intentionally module-private: app UI should traverse `card` /
  /// `Card.attachments` instead of depending on transport-shaped foreign keys.
  var cardReferenceID: UUID

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
  var primaryResourceReferenceID: UUID

  /// Optional save-time raster derivative for large raster media.
  ///
  /// Photo cards and future video poster frames may use this as a compact
  /// display payload. Authored/vector media such as Doodle and Bauhaus should
  /// keep rendering from their media file instead of storing a lossy image here.
  public var thumbnail: Data?

  public var createdAt: Date

  /// Concrete file resources that make up this logical attachment.
  @Relationship(deleteRule: .cascade, inverse: \AttachmentResource.attachment)
  public var resources: [AttachmentResource] = []

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
    self.cardReferenceID = cardID
    self.kindRawValue = kind.rawValue
    self.byteSize = byteSize
    self.primaryResourceReferenceID = primaryResourceID
    self.thumbnail = thumbnail
    self.createdAt = createdAt
  }
}

// MARK: - Relationships

extension Attachment {

  /// Stable id of the owning card.
  ///
  /// Reads from the repaired relationship when available and falls back to the
  /// sync reference while imports are still out of order.
  public var cardID: UUID {
    card?.id ?? cardReferenceID
  }

  /// Stable id of the primary resource used by renderers.
  public var primaryResourceID: UUID {
    primaryResourceReferenceID
  }

  /// Primary concrete resource, if it has been materialized locally.
  public var primaryResource: AttachmentResource? {
    resources.first { $0.id == primaryResourceReferenceID }
  }

  func setCardReferenceID(_ id: UUID) {
    cardReferenceID = id
    if card?.id != id {
      card = nil
    }
  }

  func connect(to card: Card) {
    cardReferenceID = card.id
    self.card = card
  }

  func setPrimaryResourceReferenceID(_ id: UUID) {
    primaryResourceReferenceID = id
  }
}

// MARK: - Kind

extension Attachment {

  /// The modality behind an attachment, which determines how its resources are
  /// interpreted (file -> original bytes, photo -> still image, Live Photo ->
  /// still + paired movie, video -> movie, audio -> m4a, suggestion -> authored
  /// JSON plus optional copied media, doodle / bauhaus -> encoded JSON). Raw
  /// values are stable CloudKit payload values.
  public enum Kind: String, Codable, Sendable, CaseIterable, Hashable {
    /// A generic imported file whose primary resource has the `.file` role.
    case file

    case photo
    case video
    case livePhoto
    case audio
    case suggestion
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
