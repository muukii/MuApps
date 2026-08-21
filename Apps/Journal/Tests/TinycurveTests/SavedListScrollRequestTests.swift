import Foundation
import Testing

@testable import Tinycurve

@Suite("Saved list scroll request")
struct SavedListScrollRequestTests {

  @Test("Waits until the created edge reaches the live query")
  func waitsForQuery() {
    let ownerRootID = id(1)
    let targetID = id(2)
    let request = request(ownerRootID: ownerRootID, targetID: targetID)

    #expect(
      request.resolution(
        allEdgeIDs: [ownerRootID],
        visibleRootEdgeIDs: [ownerRootID],
        targetIsVisibleInOwnerRoot: false,
        renderedEdgeIDs: [ownerRootID]
      ) == .waitForQuery
    )
  }

  @Test("Consumes a request whose owner root is hidden by the Home filter")
  func consumesHiddenOwner() {
    let ownerRootID = id(1)
    let targetID = id(2)
    let request = request(ownerRootID: ownerRootID, targetID: targetID)

    #expect(
      request.resolution(
        allEdgeIDs: [ownerRootID, targetID],
        visibleRootEdgeIDs: [],
        targetIsVisibleInOwnerRoot: false,
        renderedEdgeIDs: []
      ) == .consumeWithoutScrolling
    )
  }

  @Test("Consumes an edge that cannot participate in the visible projection")
  func consumesUnprojectedTarget() {
    let ownerRootID = id(1)
    let targetID = id(2)
    let request = request(ownerRootID: ownerRootID, targetID: targetID)

    #expect(
      request.resolution(
        allEdgeIDs: [ownerRootID, targetID],
        visibleRootEdgeIDs: [ownerRootID],
        targetIsVisibleInOwnerRoot: false,
        renderedEdgeIDs: [ownerRootID]
      ) == .consumeWithoutScrolling
    )
  }

  @Test("Materializes the owner root before revealing an offscreen Reply")
  func materializesOwnerRoot() {
    let ownerRootID = id(1)
    let targetID = id(2)
    let request = request(ownerRootID: ownerRootID, targetID: targetID)

    #expect(
      request.resolution(
        allEdgeIDs: [ownerRootID, targetID],
        visibleRootEdgeIDs: [ownerRootID],
        targetIsVisibleInOwnerRoot: true,
        renderedEdgeIDs: []
      ) == .materializeOwnerRoot(ownerRootID)
    )
  }

  @Test("Keeps one materialization action while unrelated rows enter layout")
  func coalescesUnrelatedRenderedEdges() {
    let ownerRootID = id(1)
    let targetID = id(2)
    let unrelatedID = id(3)
    let request = request(ownerRootID: ownerRootID, targetID: targetID)

    let initialResolution = request.resolution(
      allEdgeIDs: [ownerRootID, targetID, unrelatedID],
      visibleRootEdgeIDs: [ownerRootID, unrelatedID],
      targetIsVisibleInOwnerRoot: true,
      renderedEdgeIDs: []
    )
    let updatedResolution = request.resolution(
      allEdgeIDs: [ownerRootID, targetID, unrelatedID],
      visibleRootEdgeIDs: [ownerRootID, unrelatedID],
      targetIsVisibleInOwnerRoot: true,
      renderedEdgeIDs: [unrelatedID]
    )

    #expect(initialResolution == .materializeOwnerRoot(ownerRootID))
    #expect(updatedResolution == initialResolution)
  }

  @Test("Reveals a rendered root at the root anchor")
  func revealsRoot() {
    let rootID = id(1)
    let request = request(ownerRootID: rootID, targetID: rootID)

    #expect(
      request.resolution(
        allEdgeIDs: [rootID],
        visibleRootEdgeIDs: [rootID],
        targetIsVisibleInOwnerRoot: true,
        renderedEdgeIDs: [rootID]
      ) == .revealRoot(rootID)
    )
  }

  @Test("Reveals a rendered Reply inside its owner root")
  func revealsReply() {
    let ownerRootID = id(1)
    let targetID = id(2)
    let request = request(ownerRootID: ownerRootID, targetID: targetID)

    #expect(
      request.resolution(
        allEdgeIDs: [ownerRootID, targetID],
        visibleRootEdgeIDs: [ownerRootID],
        targetIsVisibleInOwnerRoot: true,
        renderedEdgeIDs: [ownerRootID, targetID]
      ) == .revealReply(targetID)
    )
  }

  @Test("Materializes a filtered root before revealing a matching nested Reply")
  func materializesRootForMatchingNestedReply() {
    let ownerRootID = id(1)
    let targetID = id(3)
    let request = request(ownerRootID: ownerRootID, targetID: targetID)

    #expect(
      request.resolution(
        allEdgeIDs: [ownerRootID, targetID],
        visibleRootEdgeIDs: [ownerRootID],
        targetIsVisibleInOwnerRoot: true,
        renderedEdgeIDs: []
      ) == .materializeOwnerRoot(ownerRootID)
    )
  }

  @Test("Consumes a nested Reply excluded by the selected kind")
  func consumesFilteredNestedReply() {
    let ownerRootID = id(1)
    let targetID = id(3)
    let request = request(ownerRootID: ownerRootID, targetID: targetID)

    #expect(
      request.resolution(
        allEdgeIDs: [ownerRootID, targetID],
        visibleRootEdgeIDs: [ownerRootID],
        targetIsVisibleInOwnerRoot: false,
        renderedEdgeIDs: [ownerRootID]
      ) == .consumeWithoutScrolling
    )
  }

  @Test("Consumes a target that moved under another visible root")
  func consumesReparentedTarget() {
    let originalOwnerRootID = id(1)
    let currentOwnerRootID = id(2)
    let targetID = id(3)
    let request = request(
      ownerRootID: originalOwnerRootID,
      targetID: targetID
    )

    #expect(
      request.resolution(
        allEdgeIDs: [originalOwnerRootID, currentOwnerRootID, targetID],
        visibleRootEdgeIDs: [originalOwnerRootID, currentOwnerRootID],
        targetIsVisibleInOwnerRoot: false,
        renderedEdgeIDs: [originalOwnerRootID, currentOwnerRootID, targetID]
      ) == .consumeWithoutScrolling
    )
  }

  private func request(ownerRootID: UUID, targetID: UUID) -> SavedListScrollRequest {
    SavedListScrollRequest(
      ownerRootEdgeID: ownerRootID,
      targetEdgeID: targetID
    )
  }

  private func id(_ suffix: Int) -> UUID {
    UUID(
      uuidString: String(format: "00000000-0000-0000-0000-%012d", suffix)
    )!
  }
}
