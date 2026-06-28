import Foundation
import SwiftData

/// A single post in the journal. Each thing the user captures becomes one Card.
///
/// CloudKit mirroring (via SwiftData) imposes modeling constraints: every
/// stored property must be optional or carry a default value, no `.unique`
/// attributes are allowed, and relationships must be optional. This model is
/// kept deliberately minimal — the journaling UI is still being designed, so
/// fields will grow as the feature takes shape.
///
/// Lives in `JournalModel` (not the app target) so both the app and the Widget
/// extension can read the same store. See [`JournalStore`](x-source-tag://JournalStore).
@Model
public final class Card {

  /// Logical identifier. CloudKit mirroring cannot enforce uniqueness
  /// (`.unique` is forbidden), so the same logical card created on two devices
  /// would produce duplicate rows — dedup is an app-level concern to handle if
  /// it ever matters.
  public var id: UUID = UUID()

  /// Primary modality of this card, and therefore the contract for which content
  /// fields are meaningful. `.text` cards read `body`; media cards expect a
  /// matching `Attachment` row and do not treat `body` as a caption.
  public var kind: Kind = Card.Kind.text

  // MARK: - Metadata

  public var createdAt: Date = Date()
  public var updatedAt: Date = Date()

  /// Tags applied to this card. Many-to-many; the inverse is declared on
  /// `Tag.cards`. Optional per the CloudKit constraint on mirrored relationships.
  public var tags: [Tag]?

  /// Media attached to this card (photos, audio, doodles). The bytes live as files
  /// on disk; these rows are only the references. `.cascade` so deleting a Card
  /// deletes its Attachment rows — the files are then reclaimed by
  /// `JournalStore.reconcileOrphanFiles`. Optional per the CloudKit constraint.
  @Relationship(deleteRule: .cascade, inverse: \Attachment.card)
  public var attachments: [Attachment]?

  /// Directed relationships that start from this card: continuations, replies,
  /// and references to later cards. Optional per the CloudKit constraint on
  /// mirrored relationships.
  @Relationship(deleteRule: .cascade, inverse: \CardRelationship.source)
  public var outgoingRelationships: [CardRelationship]?

  /// Directed relationships that point at this card from earlier or related
  /// cards. Optional per the CloudKit constraint on mirrored relationships.
  @Relationship(deleteRule: .cascade, inverse: \CardRelationship.target)
  public var incomingRelationships: [CardRelationship]?

  /// Where the card was created, recorded only when the user has granted
  /// location access. `nil` means no location (not permitted or unavailable).
  public var location: Coordinate?

  // MARK: - Content

  public var body: String = ""

  private init(
    kind: Kind,
    body: String = ""
  ) {
    self.id = UUID()
    self.kind = kind
    self.createdAt = Date()
    self.updatedAt = Date()
    self.body = body
  }

  /// Creates a written note card. Text cards use `body` as their primary
  /// content and do not require an attachment.
  public convenience init(text: String) {
    self.init(kind: .text, body: text)
  }

  /// Creates a photo card. When an attachment is provided, it is linked as the
  /// card's media payload; `body` is intentionally left empty.
  public convenience init(photo attachment: Attachment? = nil) {
    self.init(kind: .photo)
    attachMediaPayload(attachment)
  }

  /// Creates an audio card. When an attachment is provided, it is linked as the
  /// card's media payload; `body` is intentionally left empty.
  public convenience init(audio attachment: Attachment? = nil) {
    self.init(kind: .audio)
    attachMediaPayload(attachment)
  }

  /// Creates a doodle card. When an attachment is provided, it is linked as the
  /// card's media payload; `body` is intentionally left empty.
  public convenience init(doodle attachment: Attachment? = nil) {
    self.init(kind: .doodle)
    attachMediaPayload(attachment)
  }

  /// Creates a Bauhaus grid artwork card. When an attachment is provided, it is
  /// linked as the card's media payload; `body` is intentionally left empty.
  public convenience init(bauhaus attachment: Attachment? = nil) {
    self.init(kind: .bauhaus)
    attachMediaPayload(attachment)
  }

  private func attachMediaPayload(_ attachment: Attachment?) {
    guard let attachment else { return }
    attachment.card = self
    attachments = [attachment]
  }
}

// MARK: - Kind

extension Card {

  /// The top-level content modality for a `Card`.
  ///
  /// This enum is intentionally stored on `Card`, not inferred from attachments,
  /// so readers can know what content shape to expect before looking at optional
  /// relationships. The attachment table still owns the bytes; this value tells
  /// the app which relationship, if any, is required for the card to be complete.
  public enum Kind: String, Codable, Sendable, CaseIterable, Hashable {
    /// A written note. `body` is the primary content and attachments are not
    /// required for display.
    case text

    /// A still photo card. The card expects one `.photo` attachment for its bytes;
    /// `body` is not rendered as a caption.
    case photo

    /// An ambient audio card. The card expects one `.audio` attachment for its
    /// recording; text display is represented by audio-specific UI.
    case audio

    /// A doodle card. The card expects one `.doodle` attachment for the editable
    /// encoded drawing.
    case doodle

    /// A Bauhaus grid artwork card. The card expects one `.bauhaus` attachment
    /// for the encoded `BauhausGridArtwork`.
    case bauhaus

    /// A card whose modality this build does not recognize — for example one
    /// synced from a newer app version that introduced a kind this build predates.
    /// The app cannot create `.unknown` cards; it only renders them as a neutral
    /// placeholder so unfamiliar content degrades gracefully instead of failing.
    case unknown
  }

  /// The media attachment kind this card should carry, or `nil` for text cards.
  public var expectedAttachmentKind: Attachment.Kind? {
    kind.expectedAttachmentKind
  }
}

extension Card.Kind {

  /// Creates a card kind from a stored attachment kind.
  public init(attachmentKind: Attachment.Kind) {
    switch attachmentKind {
    case .photo:
      self = .photo
    case .audio:
      self = .audio
    case .doodle:
      self = .doodle
    case .bauhaus:
      self = .bauhaus
    }
  }

  /// The attachment kind required for this card kind to have complete media
  /// content. Text cards return `nil` because their content is stored in `body`.
  public var expectedAttachmentKind: Attachment.Kind? {
    switch self {
    case .text:
      return nil
    case .photo:
      return .photo
    case .audio:
      return .audio
    case .doodle:
      return .doodle
    case .bauhaus:
      return .bauhaus
    case .unknown:
      return nil
    }
  }
}
