import Foundation
import SwiftData

/// A directed relationship from one `Card` to another.
///
/// Journal cards form a graph: a thread is a path through cards, a reply tree is
/// a branching subset of that graph, and a card can eventually connect several
/// earlier cards together. Keeping the edge as its own model avoids baking a
/// single-parent tree into `Card` and leaves room for relationship kinds beyond
/// "continue this thought".
///
/// CloudKit-mirroring constraints apply as on `Card`: every stored property is
/// optional or has a default, no `.unique`, and the relationships are optional.
@Model
public final class CardRelationship {

  /// Logical identifier for this edge. CloudKit mirroring can't enforce
  /// uniqueness, so duplicate prevention is handled by `JournalStore`.
  public var id: UUID = UUID()

  /// The meaning of the directed edge.
  public var kind: Kind = Kind.continuation

  /// Creation time for the edge itself, not either endpoint.
  public var createdAt: Date = Date()

  /// Stable order among relationships of the same `kind` from the same source.
  ///
  /// Most thread views can sort by the target card's creation date, but keeping
  /// an explicit edge order lets the app preserve the user's authored sequence
  /// even if a relationship is added later or multiple children share a timestamp.
  public var sortIndex: Int = 0

  /// The card this relationship starts from. Optional per CloudKit mirroring.
  public var source: Card?

  /// The card this relationship points to. Optional per CloudKit mirroring.
  public var target: Card?

  public init(
    kind: Kind = .continuation,
    sortIndex: Int = 0,
    source: Card? = nil,
    target: Card? = nil
  ) {
    self.id = UUID()
    self.kind = kind
    self.createdAt = Date()
    self.sortIndex = sortIndex
    self.source = source
    self.target = target
  }
}

// MARK: - Kind

extension CardRelationship {

  /// The domain meaning of an edge between two cards.
  public enum Kind: String, Codable, Sendable, CaseIterable {
    /// The target card continues the source card as the next authored thought in
    /// the same chain, like posting the next item in a thread.
    case continuation

    /// The target card responds to the source card, allowing a branch to grow
    /// from an earlier card without implying it is the single next item.
    case reply

    /// The target card cites or groups itself with the source card without
    /// claiming a conversational parent/child meaning.
    case reference
  }
}
