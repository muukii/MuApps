import Foundation
import Testing

@testable import Tinycurve

@Suite("Saved entry tree projection")
@MainActor
struct SavedEntryTreeProjectionTests {

  @Test("Projects stable edge identity and sibling order at every depth")
  func projectsStableIdentityAndSiblingOrder() throws {
    let root = Entry(id: id(1), parentID: nil, sortIndex: 0)
    let laterChild = Entry(id: id(2), parentID: root.id, sortIndex: 2)
    let earlierChild = Entry(id: id(3), parentID: root.id, sortIndex: 1)
    let grandchild = Entry(
      id: id(4),
      parentID: earlierChild.id,
      sortIndex: 0
    )
    let projection = projection(
      entries: [laterChild, grandchild, root, earlierChild]
    )

    let tree = try #require(projection.tree(startingAt: root.id))

    #expect(tree.id == root.id)
    #expect(tree.children.map(\.id) == [earlierChild.id, laterChild.id])
    #expect(tree.children[0].children.map(\.id) == [grandchild.id])
  }

  @Test("Orphans remain outside a valid root subtree")
  func omitsOrphansFromRootSubtree() throws {
    let root = Entry(id: id(1), parentID: nil, sortIndex: 0)
    let child = Entry(id: id(2), parentID: root.id, sortIndex: 0)
    let orphan = Entry(id: id(3), parentID: id(99), sortIndex: 0)
    let orphanChild = Entry(id: id(4), parentID: orphan.id, sortIndex: 0)
    let projection = projection(entries: [orphanChild, orphan, child, root])

    let tree = try #require(projection.tree(startingAt: root.id))

    #expect(depthFirstIDs(in: tree) == [root.id, child.id])
    #expect(projection.tree(startingAt: orphan.id) == nil)
    #expect(projection.tree(startingAt: orphanChild.id) == nil)
  }

  @Test("A rootless cyclic component cannot become a display subtree")
  func omitsRootlessCycles() {
    let first = Entry(id: id(1), parentID: id(3), sortIndex: 0)
    let second = Entry(id: id(2), parentID: first.id, sortIndex: 0)
    let third = Entry(id: id(3), parentID: second.id, sortIndex: 0)
    let projection = projection(entries: [first, second, third])

    #expect(projection.tree(startingAt: first.id) == nil)
    #expect(projection.tree(startingAt: second.id) == nil)
    #expect(projection.tree(startingAt: third.id) == nil)
  }

  private struct Entry: Identifiable {
    let id: UUID
    let parentID: UUID?
    let sortIndex: Int
  }

  private func projection(entries: [Entry]) -> SavedEntryTreeProjection<Entry> {
    SavedEntryTreeProjection(
      entries: entries,
      parentID: { $0.parentID },
      areChildrenInIncreasingOrder: { lhs, rhs in
        if lhs.sortIndex != rhs.sortIndex {
          return lhs.sortIndex < rhs.sortIndex
        }
        return lhs.id.uuidString < rhs.id.uuidString
      }
    )
  }

  private func depthFirstIDs(
    in node: SavedEntryTreeProjection<Entry>.Node
  ) -> [UUID] {
    node.children.reduce(into: [node.id]) { result, child in
      result.append(contentsOf: depthFirstIDs(in: child))
    }
  }

  private func id(_ suffix: Int) -> UUID {
    UUID(
      uuidString: String(format: "00000000-0000-0000-0000-%012d", suffix)
    )!
  }
}
