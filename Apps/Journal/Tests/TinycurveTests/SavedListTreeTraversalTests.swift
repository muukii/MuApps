import Foundation
import JournalVault
import Testing

@testable import Tinycurve

@Suite("Saved list live tree traversal")
@MainActor
struct SavedListTreeTraversalTests {

  @Test("Keeps a matching descendant through a nonmatching ancestor")
  func keepsMatchingDescendantThroughFilteredAncestor() throws {
    let root = edge(id: 1, kind: .text)
    let ancestor = edge(id: 2, kind: .link)
    let match = edge(id: 3, kind: .todo)
    connect(ancestor, to: root)
    connect(match, to: ancestor)

    let roots = VaultSavedListTreeTraversal.activeResolvedRoots(
      from: [root, ancestor, match]
    )
    let visibleRoots = VaultSavedListTreeTraversal.visibleRoots(
      from: roots,
      selectedContentKind: .todo
    )
    let visiblePlacements = VaultSavedListTreeTraversal.visiblePlacements(
      in: visibleRoots,
      selectedContentKind: .todo
    )

    #expect(visibleRoots.map(\.id) == [root.id])
    #expect(visiblePlacements.map(\.id) == [match.id])
    #expect(
      VaultSavedListTreeTraversal.containsVisiblePlacement(
        edgeID: match.id,
        in: root,
        selectedContentKind: .todo
      )
    )
  }

  @Test("All Entries follows sibling order and skips inactive or unresolved children")
  func allEntriesFollowsOrderAndSkipsInvalidChildren() throws {
    let root = edge(id: 1, kind: .text)
    let later = edge(id: 2, kind: .todo, sortIndex: 2)
    let earlier = edge(id: 3, kind: .link, sortIndex: 1)
    let deleted = edge(id: 4, kind: .text, sortIndex: 3, deletedAt: Date())
    let unresolved = JournalVault.CardEdge(
      id: id(5),
      cardID: id(500),
      parentEdgeID: root.id,
      sortIndex: 4
    )
    connect(later, to: root)
    connect(earlier, to: root)
    connect(deleted, to: root)
    root.children.append(unresolved)

    let placements = VaultSavedListTreeTraversal.visiblePlacements(
      in: [root],
      selectedContentKind: nil
    )

    #expect(placements.map(\.id) == [root.id, earlier.id, later.id])
  }

  @Test("Orphans and rootless cycles stay outside rooted traversal")
  func omitsOrphansAndRootlessCycles() {
    let root = edge(id: 1, kind: .text)
    let orphan = edge(id: 2, kind: .todo, parentEdgeID: id(99))
    let orphanChild = edge(id: 3, kind: .todo)
    connect(orphanChild, to: orphan)

    let first = edge(id: 4, kind: .text)
    let second = edge(id: 5, kind: .todo)
    let third = edge(id: 6, kind: .link)
    connect(second, to: first)
    connect(third, to: second)
    connect(first, to: third)

    let roots = VaultSavedListTreeTraversal.activeResolvedRoots(
      from: [orphanChild, third, root, first, orphan, second]
    )
    let placements = VaultSavedListTreeTraversal.visiblePlacements(
      in: roots,
      selectedContentKind: nil
    )

    #expect(roots.map(\.id) == [root.id])
    #expect(placements.map(\.id) == [root.id])
  }

  @Test("A cycle guard is local to each path and does not hide valid siblings")
  func cycleGuardPreservesValidSibling() {
    let root = edge(id: 1, kind: .text)
    let cycleChild = edge(id: 2, kind: .link)
    let matchingSibling = edge(id: 3, kind: .todo, sortIndex: 1)
    connect(cycleChild, to: root)
    connect(matchingSibling, to: root, sortIndex: 1)
    connect(root, to: cycleChild)

    let placements = VaultSavedListTreeTraversal.visiblePlacements(
      in: [root],
      selectedContentKind: .todo
    )

    #expect(placements.map(\.id) == [matchingSibling.id])
  }

  private func edge(
    id suffix: Int,
    kind: JournalVault.Card.Kind,
    sortIndex: Int = 0,
    parentEdgeID: UUID? = nil,
    deletedAt: Date? = nil
  ) -> JournalVault.CardEdge {
    let card = JournalVault.Card(id: id(suffix * 100), kind: kind)
    let edge = JournalVault.CardEdge(
      id: id(suffix),
      cardID: card.id,
      parentEdgeID: parentEdgeID,
      sortIndex: sortIndex,
      deletedAt: deletedAt
    )
    edge.card = card
    return edge
  }

  private func connect(
    _ child: JournalVault.CardEdge,
    to parent: JournalVault.CardEdge,
    sortIndex: Int? = nil
  ) {
    child.parent = parent
    if let sortIndex {
      child.sortIndex = sortIndex
    }
    parent.children.append(child)
  }

  private func id(_ suffix: Int) -> UUID {
    UUID(
      uuidString: String(format: "00000000-0000-0000-0000-%012d", suffix)
    )!
  }
}
