import Foundation
import SwiftData

/// A label a user can apply to many `Card`s to group them.
///
/// Same CloudKit-mirroring constraints as `Card`: every stored property is
/// optional or has a default, no `.unique` attribute (so the same tag name can
/// exist as duplicate rows across devices — dedup, if it ever matters, is an
/// app-level concern), and the relationship is optional.
@Model
public final class Tag {

  public var id: UUID = UUID()
  public var name: String = ""
  public var createdAt: Date = Date()

  /// Inverse of `Card.tags`. The inverse is declared on this side only;
  /// declaring it on both sides is a SwiftData error. Optional per the CloudKit
  /// constraint that mirrored relationships must be optional.
  @Relationship(inverse: \Card.tags)
  public var cards: [Card]?

  public init(name: String) {
    self.id = UUID()
    self.name = name
    self.createdAt = Date()
  }
}
