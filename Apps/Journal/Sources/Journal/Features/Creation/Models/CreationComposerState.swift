import Foundation
import JournalVault

/// Persistence destination frozen when posting begins.
///
/// The value prevents a later Reply selection during an asynchronous save from
/// retargeting authored content to a different tree placement.
enum CreationPostDestination: Equatable, Sendable {
  case root
  case reply(SavedListReplyTarget)
}

/// Frozen input handed from the composer owner to the persistence consumer.
///
/// The snapshot and destination are captured synchronously before persistence
/// can suspend. `sourceDraftID` is retained only as a stable identity token so
/// a later successful completion can reset the draft that actually initiated
/// the write without retaining a mutable draft as the persistence contract.
struct CreationComposerSubmission: Sendable {

  let snapshot: CardEditDraftSnapshot
  let destination: CreationPostDestination
  let sourceDraftID: UUID
}

enum CreationPostError: Error {
  case missingCreatedEdge
}

/// Owns one unpublished draft for Home and one for every selected Reply parent.
///
/// Reply selection is explicit and independent from navigation. Drafts are
/// keyed by vault and parent placement so changing context never silently moves
/// authored content to another relationship. This type is internal so its
/// ownership and in-flight completion rules can be verified without rendering
/// the SwiftUI hierarchy.
@MainActor
@Observable
final class CreationComposerSession {

  private var rootDraft = CardEditDraft()
  private var replyDrafts: [ReplyDraftKey: CardEditDraft] = [:]

  init(rootDraft: CardEditDraft = CardEditDraft()) {
    self.rootDraft = rootDraft
  }

  /// Explicit parent selected from an entry context menu.
  private(set) var replyTarget: SavedListReplyTarget?

  /// Whether the selected parent still exists in the active vault query.
  ///
  /// Unavailability never falls back to root; it only disables posting until
  /// the user cancels Reply or the placement becomes available again.
  private(set) var isReplyTargetAvailable = true

  /// One-shot identity used to focus an inline Text or Todo field after Reply
  /// is selected from a context menu.
  private(set) var focusRequestID: UUID?

  var activeDraft: CardEditDraft {
    guard let replyTarget else {
      return rootDraft
    }
    let key = ReplyDraftKey(replyTarget)
    guard let draft = replyDrafts[key] else {
      assertionFailure("A selected Reply target must own a draft.")
      return rootDraft
    }
    return draft
  }

  var activeDestination: CreationPostDestination {
    guard let replyTarget else { return .root }
    return .reply(replyTarget)
  }

  var placement: CreationComposerPlacement {
    replyTarget == nil ? .root : .reply
  }

  var hasAuthoredDrafts: Bool {
    rootDraft.isEmptyComposerDraft == false
      || replyDrafts.values.contains { $0.isEmptyComposerDraft == false }
  }

  /// Switches the active compact composer between Text and Todo mode.
  ///
  /// The active destination keeps owning its mode alongside its draft. The
  /// input bar owns focus because mode changes are a local authoring action.
  func toggleActiveComposerMode() {
    activeDraft.toggleComposerMode()
  }

  /// Freezes the active draft and destination before the persistence boundary.
  ///
  /// The input bar calls this synchronously from its submit action. Returning a
  /// value object here keeps the parent from re-reading mutable composer state
  /// after the event has already been accepted by the UI.
  func makeSubmission() -> CreationComposerSubmission? {
    let draft = activeDraft
    guard draft.canSave else { return nil }

    return CreationComposerSubmission(
      snapshot: draft.savingSnapshot(),
      destination: activeDestination,
      sourceDraftID: draft.displayID
    )
  }

  /// Returns whether the current destination is safe to persist in the
  /// selected vault. Root only needs an active vault; Reply additionally needs
  /// its detached vault identity and live placement availability to match.
  func isActiveDestinationAvailable(in selectedVaultID: VaultID?) -> Bool {
    isDestinationAvailable(activeDestination, in: selectedVaultID)
  }

  /// Returns whether a previously frozen destination is still safe to persist
  /// in the selected vault without consulting the mutable active selection.
  func isDestinationAvailable(
    _ destination: CreationPostDestination,
    in selectedVaultID: VaultID?
  ) -> Bool {
    guard let selectedVaultID else { return false }
    switch destination {
    case .root:
      return true
    case .reply(let replyTarget):
      return replyTarget.vaultID == selectedVaultID
        && isReplyTargetAvailable(for: replyTarget)
    }
  }

  private func isReplyTargetAvailable(for target: SavedListReplyTarget) -> Bool {
    guard let replyTarget else { return false }
    return ReplyDraftKey(replyTarget) == ReplyDraftKey(target)
      && isReplyTargetAvailable
  }

  /// Selects a Reply placement and restores its independent unpublished draft.
  func selectReplyTarget(_ target: SavedListReplyTarget) {
    let key = ReplyDraftKey(target)
    if replyDrafts[key] == nil {
      replyDrafts[key] = CardEditDraft()
    }
    replyTarget = target
    // Context-menu targets originate from a live visible row. SavedList will
    // revalidate this optimistic value against its next query snapshot.
    isReplyTargetAvailable = true
    focusRequestID = UUID()
  }

  /// Consumes one pending focus request exactly once.
  ///
  /// A child consumes synchronously before yielding for context-menu dismissal.
  /// Clearing the ID here prevents a recreated SwiftUI subtree from accepting
  /// the same request during Map navigation or other structural changes.
  @discardableResult
  func consumeFocusRequest(_ requestID: UUID) -> Bool {
    guard focusRequestID == requestID else { return false }
    focusRequestID = nil
    return true
  }

  /// Applies the SavedList query's latest availability for the selected parent.
  func setReplyTargetAvailability(_ isAvailable: Bool) {
    guard replyTarget != nil else {
      isReplyTargetAvailable = true
      return
    }
    isReplyTargetAvailable = isAvailable
  }

  /// Returns the composer to its root draft without discarding the Reply draft.
  func cancelReply(requestFocus: Bool = true) {
    replyTarget = nil
    isReplyTargetAvailable = true
    focusRequestID = requestFocus ? UUID() : nil
  }

  /// Completes exactly the draft and destination captured when posting began.
  ///
  /// The posted Reply draft is reset even if the user moved elsewhere while the
  /// save ran. The visible target is cleared only when it still represents the
  /// same parent, so a later selection is never clobbered by older work.
  @discardableResult
  func completePost(_ submission: CreationComposerSubmission) -> Bool {
    guard
      resetDraft(
        for: submission.destination,
        ifMatchingSourceID: submission.sourceDraftID
      )
    else {
      return false
    }

    if case .reply(let postedTarget) = submission.destination,
      replyTarget.map(ReplyDraftKey.init) == ReplyDraftKey(postedTarget)
    {
      cancelReply()
    }
    return true
  }

  @discardableResult
  private func resetDraft(
    for destination: CreationPostDestination,
    ifMatchingSourceID sourceDraftID: UUID
  ) -> Bool {
    switch destination {
    case .root:
      guard rootDraft.displayID == sourceDraftID else { return false }
      rootDraft = rootDraft.emptyComposerReplacement()
    case .reply(let target):
      let key = ReplyDraftKey(target)
      guard let draft = replyDrafts[key], draft.displayID == sourceDraftID else { return false }
      replyDrafts[key] = draft.emptyComposerReplacement()
    }
    return true
  }

  func discardActiveDraft() {
    let draft = activeDraft
    draft.savingSnapshot().removeTemporaryMediaFiles()
    resetDraft(for: activeDestination, ifMatchingSourceID: draft.displayID)
  }

  func discardAllDrafts() {
    rootDraft.savingSnapshot().removeTemporaryMediaFiles()
    for draft in replyDrafts.values {
      draft.savingSnapshot().removeTemporaryMediaFiles()
    }
    rootDraft = CardEditDraft()
    replyDrafts.removeAll(keepingCapacity: false)
    cancelReply(requestFocus: false)
  }

  /// Stable draft ownership key for one Reply placement.
  private struct ReplyDraftKey: Hashable {
    let vaultID: VaultID
    let parentEdgeID: UUID

    init(_ target: SavedListReplyTarget) {
      vaultID = target.vaultID
      parentEdgeID = target.parentEdgeID
    }
  }
}
