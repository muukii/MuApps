import Foundation
import SwiftData

/// A content atom: one captured thing (a note, a link, a photo, a video, a doodle...).
///
/// Where the card sits in the vault's tree is expressed separately by
/// `CardEdge`; every visible card is referenced by exactly one edge.
///
/// CloudKit mirroring is disabled for this store, so `.unique` and non-optional
/// properties are fine.
/// CloudKit record ids stay as stable UUIDs, while SwiftData relationships keep
/// the app UI on the local object graph instead of manual CloudKit-shaped joins.
@Model
public final class Card {

  @Attribute(.unique)
  public var id: UUID

  /// Raw modality string as stored and synced. Kept as a string (not the
  /// `Kind` enum) so a card kind introduced by a newer app version survives a
  /// round-trip through this build unchanged instead of collapsing to
  /// `"unknown"`. Read through `kind` unless re-encoding for transport.
  public var kindRawValue: String

  /// Body-backed payload for card metadata. `.text` and `.todo` store written
  /// content, `.link` stores the canonical URL string, and `.file` stores the
  /// original user-facing file name. Other media and authored JSON kinds keep
  /// this empty and point at `Attachment` rows instead.
  public var body: String

  /// When this Todo was completed, or `nil` while it remains open.
  ///
  /// The optional timestamp is the single persisted completion source of truth;
  /// `isCompleted` is deliberately derived instead of storing a duplicate Bool.
  /// Non-Todo cards keep this value `nil`.
  public var completedAt: Date?

  public var createdAt: Date
  public var updatedAt: Date

  /// Where the card was created, recorded only when the user opted in.
  public var location: Coordinate?

  /// Media or authored payload rows owned by this card.
  ///
  /// Text and link cards usually have no attachments. Media and authored JSON
  /// cards use one logical attachment whose resources hold concrete files.
  @Relationship(deleteRule: .cascade, inverse: \Attachment.card)
  public var attachments: [Attachment] = []

  /// Tree placements that make this card visible inside a vault.
  ///
  /// A valid vault normally has one placement per visible card. The array shape
  /// keeps the relationship tolerant of partially imported or repaired data.
  @Relationship(inverse: \CardEdge.card)
  public var placements: [CardEdge] = []

  public init(
    id: UUID = UUID(),
    kind: Kind = .text,
    body: String = "",
    completedAt: Date? = nil,
    createdAt: Date = Date(),
    updatedAt: Date = Date(),
    location: Coordinate? = nil
  ) {
    self.id = id
    self.kindRawValue = kind.rawValue
    self.body = body
    self.completedAt = kind == .todo ? completedAt : nil
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

    /// One actionable item. `body` stores its text and `completedAt` stores its
    /// completion timestamp when finished.
    case todo

    /// A web link card. `body` stores the canonical URL string.
    case link

    /// A generic imported file. `body` stores its original display name and a
    /// `.file` attachment owns the concrete bytes and content-type metadata.
    case file

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

    /// A selected Apple Journaling Suggestion; expects one `.suggestion`
    /// attachment with an `.authoredJSON` payload resource and optional copied
    /// suggestion media resources.
    case suggestion

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
    set {
      kindRawValue = newValue.rawValue
      if newValue != .todo {
        completedAt = nil
      }
    }
  }

  /// Whether this Todo has a completion timestamp.
  public var isCompleted: Bool {
    kind == .todo && completedAt != nil
  }
}
