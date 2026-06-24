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

  // MARK: - Metadata

  public var createdAt: Date = Date()
  public var updatedAt: Date = Date()

  /// Tags applied to this card. Many-to-many; the inverse is declared on
  /// `Tag.cards`. Optional per the CloudKit constraint on mirrored relationships.
  public var tags: [Tag]?

  /// Where the card was created, recorded only when the user has granted
  /// location access. `nil` means no location (not permitted or unavailable).
  public var location: Coordinate?

  // MARK: - Content

  public var title: String = ""
  public var body: String = ""

  public init(title: String = "", body: String = "") {
    self.id = UUID()
    self.createdAt = Date()
    self.updatedAt = Date()
    self.title = title
    self.body = body
  }
}
