import Foundation
import JournalVault
import Testing

@testable import Tinycurve

@Suite("Creation composer Reply state")
@MainActor
struct CreationComposerStateTests {

  @Test("Root and every Reply parent preserve isolated drafts")
  func preservesDraftsPerDestination() {
    let state = CreationComposerSession()
    let vaultID = VaultID()
    let firstTarget = target(vaultID: vaultID, parentSuffix: 1)
    let secondTarget = target(vaultID: vaultID, parentSuffix: 2)

    let rootDraft = state.activeDraft
    rootDraft.text = "Root draft"

    state.selectReplyTarget(firstTarget)
    let firstReplyDraft = state.activeDraft
    firstReplyDraft.text = "First reply"

    state.selectReplyTarget(secondTarget)
    let secondReplyDraft = state.activeDraft
    secondReplyDraft.text = "Second reply"

    state.cancelReply(requestFocus: false)
    #expect(state.activeDraft === rootDraft)
    #expect(state.activeDraft.text == "Root draft")

    state.selectReplyTarget(firstTarget)
    #expect(state.activeDraft === firstReplyDraft)
    #expect(state.activeDraft.text == "First reply")

    state.selectReplyTarget(secondTarget)
    #expect(state.activeDraft === secondReplyDraft)
    #expect(state.activeDraft.text == "Second reply")
  }

  @Test("Root and Reply preserve isolated composer modes")
  func preservesModesPerDestination() {
    let state = CreationComposerSession()
    let replyTarget = target(vaultID: VaultID(), parentSuffix: 1)

    state.toggleActiveComposerMode()
    #expect(state.activeDraft.composerMode == .todo)

    state.selectReplyTarget(replyTarget)
    #expect(state.activeDraft.composerMode == .text)

    state.toggleActiveComposerMode()
    #expect(state.activeDraft.composerMode == .todo)

    state.cancelReply(requestFocus: false)
    #expect(state.activeDraft.composerMode == .todo)
  }

  @Test("Submission freezes the draft snapshot and destination")
  func freezesSubmissionBeforeLaterEdits() throws {
    let state = CreationComposerSession()
    let draft = state.activeDraft
    draft.text = "Before submit"

    let submission = try #require(state.makeSubmission())
    draft.text = "After submit"
    state.toggleActiveComposerMode()

    #expect(submission.snapshot.text == "Before submit")
    #expect(submission.snapshot.kind == .text)
    #expect(submission.destination == .root)
    #expect(submission.sourceDraftID == draft.displayID)
  }

  @Test("Successful Todo post keeps Todo mode for consecutive capture")
  func retainsTodoModeAfterPost() throws {
    let state = CreationComposerSession()
    let postedDraft = state.activeDraft
    postedDraft.setComposerMode(.todo)
    postedDraft.text = "First task"

    let submission = try #require(state.makeSubmission())
    #expect(state.completePost(submission))
    #expect(state.activeDraft !== postedDraft)
    #expect(state.activeDraft.composerMode == .todo)
    #expect(state.activeDraft.isEmptyComposerDraft)
    #expect(state.hasAuthoredDrafts == false)

    let replacementDraft = state.activeDraft
    replacementDraft.text = "Second task"
    #expect(state.completePost(submission) == false)
    #expect(state.activeDraft === replacementDraft)
    #expect(state.activeDraft.text == "Second task")
  }

  @Test("Discard clears Todo content without turning off Todo mode")
  func retainsTodoModeAfterDiscard() {
    let state = CreationComposerSession()
    state.activeDraft.setComposerMode(.todo)
    state.activeDraft.text = "Discard me"

    state.discardActiveDraft()

    #expect(state.activeDraft.composerMode == .todo)
    #expect(state.activeDraft.isEmptyComposerDraft)
    #expect(state.hasAuthoredDrafts == false)
  }

  @Test("Unavailable Reply never becomes a root destination")
  func keepsUnavailableReplyExplicit() {
    let state = CreationComposerSession()
    let vaultID = VaultID()
    let replyTarget = target(vaultID: vaultID, parentSuffix: 1)

    state.selectReplyTarget(replyTarget)
    state.setReplyTargetAvailability(false)

    #expect(state.activeDestination == .reply(replyTarget))
    #expect(state.isActiveDestinationAvailable(in: vaultID) == false)
    #expect(state.isActiveDestinationAvailable(in: VaultID()) == false)

    state.cancelReply(requestFocus: false)
    #expect(state.activeDestination == .root)
    #expect(state.isActiveDestinationAvailable(in: vaultID))
  }

  @Test("Matching Reply success clears only that Reply")
  func completesMatchingReply() throws {
    let state = CreationComposerSession()
    let replyTarget = target(vaultID: VaultID(), parentSuffix: 1)

    state.selectReplyTarget(replyTarget)
    let postedDraft = state.activeDraft
    postedDraft.text = "Posted reply"
    let submission = try #require(state.makeSubmission())

    #expect(state.completePost(submission))
    #expect(state.replyTarget == nil)
    #expect(state.activeDestination == .root)

    state.selectReplyTarget(replyTarget)
    #expect(state.activeDraft !== postedDraft)
    #expect(state.activeDraft.isEmptyTextDraft)
  }

  @Test("Failed or stale completion retains the active Reply draft")
  func rejectsMismatchedDraftCompletion() {
    let state = CreationComposerSession()
    let replyTarget = target(vaultID: VaultID(), parentSuffix: 1)

    state.selectReplyTarget(replyTarget)
    let activeDraft = state.activeDraft
    activeDraft.setComposerMode(.todo)
    activeDraft.text = "Retry me"

    #expect(
      state.completePost(
        CreationComposerSubmission(
          snapshot: activeDraft.savingSnapshot(),
          destination: state.activeDestination,
          sourceDraftID: CardEditDraft(text: "Different object").displayID
        )
      ) == false
    )
    #expect(state.replyTarget == replyTarget)
    #expect(state.activeDraft === activeDraft)
    #expect(state.activeDraft.composerMode == .todo)
    #expect(state.activeDraft.text == "Retry me")
  }

  @Test("Older Reply completion does not clobber a newer selection")
  func preservesNewerSelectionDuringInflightCompletion() throws {
    let state = CreationComposerSession()
    let vaultID = VaultID()
    let firstTarget = target(vaultID: vaultID, parentSuffix: 1)
    let secondTarget = target(vaultID: vaultID, parentSuffix: 2)

    state.selectReplyTarget(firstTarget)
    let firstDraft = state.activeDraft
    firstDraft.text = "First"
    let submission = try #require(state.makeSubmission())

    state.selectReplyTarget(secondTarget)
    let secondDraft = state.activeDraft
    secondDraft.text = "Second"

    #expect(
      state.completePost(submission)
    )
    #expect(state.replyTarget == secondTarget)
    #expect(state.activeDraft === secondDraft)
    #expect(state.activeDraft.text == "Second")

    state.selectReplyTarget(firstTarget)
    #expect(state.activeDraft !== firstDraft)
    #expect(state.activeDraft.isEmptyTextDraft)
  }

  @Test("The same edge in another Vault owns another Reply draft")
  func scopesReplyDraftsToVault() {
    let state = CreationComposerSession()
    let parentEdgeID = id(1)
    let firstTarget = SavedListReplyTarget(
      vaultID: VaultID(),
      parentEdgeID: parentEdgeID,
      ownerRootEdgeID: id(2),
      displaySummary: "First Vault"
    )
    let secondTarget = SavedListReplyTarget(
      vaultID: VaultID(),
      parentEdgeID: parentEdgeID,
      ownerRootEdgeID: id(3),
      displaySummary: "Second Vault"
    )

    state.selectReplyTarget(firstTarget)
    let firstDraft = state.activeDraft
    firstDraft.text = "First"

    state.selectReplyTarget(secondTarget)
    let secondDraft = state.activeDraft
    secondDraft.text = "Second"

    #expect(secondDraft !== firstDraft)
    state.selectReplyTarget(firstTarget)
    #expect(state.activeDraft === firstDraft)
    #expect(state.activeDraft.text == "First")
  }

  @Test("Focus requests can be consumed only once")
  func consumesFocusRequestsOnce() throws {
    let state = CreationComposerSession()
    let firstTarget = target(vaultID: VaultID(), parentSuffix: 1)

    state.selectReplyTarget(firstTarget)
    let firstRequestID = try #require(state.focusRequestID)

    #expect(state.consumeFocusRequest(firstRequestID))
    #expect(state.focusRequestID == nil)
    #expect(state.consumeFocusRequest(firstRequestID) == false)
  }

  @Test("Cancelling Reply owns a new one-shot root focus request")
  func consumesCancelFocusRequestOnce() throws {
    let state = CreationComposerSession()
    let replyTarget = target(vaultID: VaultID(), parentSuffix: 1)

    state.selectReplyTarget(replyTarget)
    let selectionRequestID = try #require(state.focusRequestID)
    #expect(state.consumeFocusRequest(selectionRequestID))

    state.cancelReply()
    let cancelRequestID = try #require(state.focusRequestID)

    #expect(cancelRequestID != selectionRequestID)
    #expect(state.consumeFocusRequest(cancelRequestID))
    #expect(state.focusRequestID == nil)
    #expect(state.consumeFocusRequest(cancelRequestID) == false)
  }

  @Test("Cancelling without focus discards an unconsumed request")
  func clearsFocusRequestWhenCancellationDoesNotRefocus() throws {
    let state = CreationComposerSession()

    state.selectReplyTarget(target(vaultID: VaultID(), parentSuffix: 1))
    let pendingRequestID = try #require(state.focusRequestID)
    state.cancelReply(requestFocus: false)

    #expect(state.focusRequestID == nil)
    #expect(state.consumeFocusRequest(pendingRequestID) == false)
  }

  @Test("A stale focus acknowledgement cannot consume a newer request")
  func rejectsStaleFocusAcknowledgement() throws {
    let state = CreationComposerSession()
    let vaultID = VaultID()

    state.selectReplyTarget(target(vaultID: vaultID, parentSuffix: 1))
    let staleRequestID = try #require(state.focusRequestID)

    state.selectReplyTarget(target(vaultID: vaultID, parentSuffix: 2))
    let currentRequestID = try #require(state.focusRequestID)

    #expect(currentRequestID != staleRequestID)
    #expect(state.consumeFocusRequest(staleRequestID) == false)
    #expect(state.focusRequestID == currentRequestID)
    #expect(state.consumeFocusRequest(currentRequestID))
    #expect(state.focusRequestID == nil)
  }

  private func target(
    vaultID: VaultID,
    parentSuffix: Int
  ) -> SavedListReplyTarget {
    SavedListReplyTarget(
      vaultID: vaultID,
      parentEdgeID: id(parentSuffix),
      ownerRootEdgeID: id(100),
      displaySummary: "Entry \(parentSuffix)"
    )
  }

  private func id(_ suffix: Int) -> UUID {
    UUID(
      uuidString: String(format: "00000000-0000-0000-0000-%012d", suffix)
    )!
  }
}
