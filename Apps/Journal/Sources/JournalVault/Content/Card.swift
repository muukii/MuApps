import Foundation
import SwiftData

/// A content atom: one captured thing (a note, a link, a photo, a video, a doodle...).
///
/// Where the card sits in the vault's tree is expressed separately by
/// `CardEdge`; every visible card is referenced by exactly one edge.
///
/// CloudKit mirroring is disabled for this store, so `.unique` and non-optional
/// properties are fine.
/// There are deliberately **no SwiftData relationships**: rows reference each
/// other by UUID exactly as their CloudKit records do, which keeps record
/// mapping 1:1 and keeps deletion cascades an explicit domain rule
/// (see `VaultContentStore.deleteCardEdge`).
@Model
public final class Card {

  @Attribute(.unique)
  public var id: UUID

  /// Raw modality string as stored and synced. Kept as a string (not the
  /// `Kind` enum) so a card kind introduced by a newer app version survives a
  /// round-trip through this build unchanged instead of collapsing to
  /// `"unknown"`. Read through `kind` unless re-encoding for transport.
  public var kindRawValue: String

  /// Body-backed payload for textual card kinds. `.text` stores written content;
  /// `.link` stores the canonical URL string. Media kinds keep this empty and
  /// point at `Attachment` rows instead.
  public var body: String

  public var createdAt: Date
  public var updatedAt: Date

  /// Where the card was created, recorded only when the user opted in.
  public var location: Coordinate?

  public init(
    id: UUID = UUID(),
    kind: Kind = .text,
    body: String = "",
    createdAt: Date = Date(),
    updatedAt: Date = Date(),
    location: Coordinate? = nil
  ) {
    self.id = id
    self.kindRawValue = kind.rawValue
    self.body = body
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.location = location
  }
}

// MARK: - Kind

extension Card {

  /// The top-level content modality for a `Card`. Raw values are stable
  /// CloudKit payload values, so newer app versions can introduce kinds without
  /// older builds rewriting them to `unknown`.
  public enum Kind: String, Codable, Sendable, CaseIterable, Hashable {
    /// A written note. `body` is the primary content.
    case text

    /// A web link card. `body` stores the canonical URL string.
    case link

    /// A still photo card; expects one `.photo` attachment.
    case photo

    /// A video card; expects one `.video` attachment with an `.originalVideo`
    /// primary resource.
    case video

    /// A Live Photo card; expects one `.livePhoto` attachment whose primary
    /// resource is `.stillImage` and whose paired movie is `.pairedVideo`.
    case livePhoto

    /// An ambient audio card; expects one `.audio` attachment.
    case audio

    /// A doodle card; expects one `.doodle` attachment.
    case doodle

    /// A Bauhaus grid artwork card; expects one `.bauhaus` attachment.
    case bauhaus

    /// A modality this build does not recognize — synced from a newer app
    /// version. Never user-creatable; rendered as a neutral placeholder.
    case unknown
  }

  /// Typed view over `kindRawValue`. Unrecognized raw values read as `.unknown`.
  public var kind: Kind {
    get { Kind(rawValue: kindRawValue) ?? .unknown }
    set { kindRawValue = newValue.rawValue }
  }
}
