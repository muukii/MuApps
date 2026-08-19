import Foundation
import SwiftData

/// The change semantic that Tinycurve projects into an existing Messages
/// collaboration highlight.
///
/// `VaultActivity.Kind` intentionally remains ``VaultActivity/Kind/contentAdded``
/// for both cases. The distinction belongs to the content-tree topology and is
/// derived only when the app prepares the Shared with You side effect.
public enum VaultSharedWithYouNoticeChange: Equatable, Hashable, Sendable {
  /// A new root post changed the collaboration's primary content.
  case edit

  /// A Reply changed an existing root post's discussion.
  case comment
}

/// Immutable Activity data needed to post one Shared with You notice.
///
/// This value crosses from the local SwiftData store into the app target. It
/// deliberately contains no `SWCollaborationHighlight` or CloudKit object, so
/// the JournalVault target remains extension-safe and owns no Messages UI.
public struct VaultSharedWithYouNoticeCandidate: Equatable, Hashable, Sendable {

  /// Stable Activity identity and local notice idempotency key.
  public let activityID: UUID

  /// Placement created by the authored action, when the Activity retained it.
  public let subjectEdgeID: UUID?

  /// Root placement that owns ``subjectEdgeID``'s thread, when known.
  public let rootEdgeID: UUID?

  public init(
    activityID: UUID,
    subjectEdgeID: UUID?,
    rootEdgeID: UUID?
  ) {
    self.activityID = activityID
    self.subjectEdgeID = subjectEdgeID
    self.rootEdgeID = rootEdgeID
  }

  /// Messages change event derived from the Activity's immutable placement
  /// topology.
  ///
  /// A valid root writes the same nonoptional edge identity into `subject` and
  /// `root`. Missing topology is conservatively a comment: an imported or
  /// future Activity must not be presented as a root edit merely because two
  /// absent optional values compare equal.
  public var change: VaultSharedWithYouNoticeChange {
    guard let subjectEdgeID else { return .comment }
    return subjectEdgeID == rootEdgeID ? .edit : .comment
  }
}

/// Durable local delivery store for Shared with You update notices.
///
/// The store owns only the post-acknowledgement state machine. Creating the
/// local intent belongs to ``VaultContentStore`` and changing it from waiting
/// to ready belongs to the CloudKit acknowledgement transaction in
/// ``VaultSyncDatabase``. Keeping those transitions separate prevents remote
/// imports or retry paths from becoming notice authors.
public actor VaultSharedWithYouNoticeStore: ModelActor {

  public nonisolated let modelExecutor: any ModelExecutor
  public nonisolated let modelContainer: ModelContainer
  private let authoredWriteCoordinator: VaultAuthoredWriteCoordinator

  /// Result of recording one transient highlight lookup failure.
  public enum LookupFailureDisposition: Equatable, Sendable {
    /// Keep the row ready for a future app start or active-scene drain.
    case retryScheduled(attemptCount: Int)

    /// The bounded retry budget was exhausted, so the row is terminal.
    case skipped
  }

  /// Creates a serial delivery state-machine owner for one vault store.
  public init(store: VaultContentStore) {
    modelContainer = store.container
    authoredWriteCoordinator = store.authoredWriteCoordinator
    let context = ModelContext(store.container)
    context.autosaveEnabled = false
    modelExecutor = DefaultSerialModelExecutor(modelContext: context)
  }

  /// Returns a bounded snapshot of rows ready to be projected into Messages.
  ///
  /// A ready row whose Activity vanished is terminally skipped in the same
  /// local transaction. Retention and remote deletion may remove history while
  /// the app was away; such a row must not remain ready forever or post a
  /// notice without durable activity history. `excluding` lets one app drain
  /// advance beyond a prior transient failure without retrying that Activity in
  /// the same lifecycle pass.
  public func readyCandidates(
    limit: Int,
    excluding excludedActivityIDs: Set<UUID> = [],
    now: Date
  ) throws -> [VaultSharedWithYouNoticeCandidate] {
    try withFreshCrossProcessState {
      try readyCandidatesInCurrentContext(
        limit: limit,
        excluding: excludedActivityIDs,
        now: now
      )
    }
  }

  private func readyCandidatesInCurrentContext(
    limit: Int,
    excluding excludedActivityIDs: Set<UUID>,
    now: Date
  ) throws -> [VaultSharedWithYouNoticeCandidate] {
    guard limit > 0 else { return [] }

    // A missing Activity is made terminal below. Re-read after a wholly stale
    // page so callers do not mistake it for the end of the ready queue.
    while true {
      let result = try readyCandidatesPageInCurrentContext(
        limit: limit,
        excluding: excludedActivityIDs,
        now: now
      )
      if result.candidates.isEmpty == false || result.didSkipMissingActivity == false {
        return result.candidates
      }
    }
  }

  private func readyCandidatesPageInCurrentContext(
    limit: Int,
    excluding excludedActivityIDs: Set<UUID>,
    now: Date
  ) throws -> (
    candidates: [VaultSharedWithYouNoticeCandidate],
    didSkipMissingActivity: Bool
  ) {
    let readyRawValue = PendingSharedWithYouNotice.State.ready.rawValue
    var descriptor = FetchDescriptor<PendingSharedWithYouNotice>(
      predicate: #Predicate { $0.stateRawValue == readyRawValue },
      sortBy: [SortDescriptor(\.createdAt)]
    )
    let (requestedFetchLimit, overflowed) = limit.addingReportingOverflow(
      excludedActivityIDs.count
    )
    descriptor.fetchLimit = overflowed ? Int.max : requestedFetchLimit

    let notices = try modelContext.fetch(descriptor)
    var candidates: [VaultSharedWithYouNoticeCandidate] = []
    var didSkipMissingActivity = false

    for notice in notices {
      guard excludedActivityIDs.contains(notice.activityID) == false else {
        continue
      }

      guard let activity = try fetchActivity(notice.activityID) else {
        notice.stateRawValue = PendingSharedWithYouNotice.State.skipped.rawValue
        notice.lastAttemptAt = now
        didSkipMissingActivity = true
        continue
      }

      candidates.append(
        VaultSharedWithYouNoticeCandidate(
          activityID: activity.id,
          subjectEdgeID: activity.subjectEdgeID,
          rootEdgeID: activity.rootEdgeID
        )
      )

      if candidates.count == limit {
        break
      }
    }

    if didSkipMissingActivity {
      try modelContext.save()
    }
    return (candidates, didSkipMissingActivity)
  }

  /// Marks a ready intent terminally skipped when Messages collaboration cannot
  /// produce a highlight for the vault's current share.
  @discardableResult
  public func markSkipped(activityID: UUID, at date: Date) throws -> Bool {
    try withFreshCrossProcessState {
      try markSkippedInCurrentContext(activityID: activityID, at: date)
    }
  }

  private func markSkippedInCurrentContext(activityID: UUID, at date: Date) throws -> Bool {
    guard let notice = try fetchNotice(activityID: activityID), notice.state == .ready else {
      return false
    }

    notice.stateRawValue = PendingSharedWithYouNotice.State.skipped.rawValue
    notice.lastAttemptAt = date
    try modelContext.save()
    return true
  }

  /// Records a recoverable highlight lookup failure without retrying it in the
  /// same drain.
  ///
  /// A new app start, active-scene event, or later ready event owns the next
  /// attempt. Once `maximumAttempts` failures are persisted, the row becomes
  /// terminal so local-only intent rows cannot grow forever on unsupported or
  /// temporarily misconfigured systems.
  public func recordTransientLookupFailure(
    activityID: UUID,
    maximumAttempts: Int,
    at date: Date
  ) throws -> LookupFailureDisposition? {
    try withFreshCrossProcessState {
      try recordTransientLookupFailureInCurrentContext(
        activityID: activityID,
        maximumAttempts: maximumAttempts,
        at: date
      )
    }
  }

  private func recordTransientLookupFailureInCurrentContext(
    activityID: UUID,
    maximumAttempts: Int,
    at date: Date
  ) throws -> LookupFailureDisposition? {
    guard let notice = try fetchNotice(activityID: activityID), notice.state == .ready else {
      return nil
    }

    notice.attemptCount += 1
    notice.lastAttemptAt = date

    if notice.attemptCount >= max(1, maximumAttempts) {
      notice.stateRawValue = PendingSharedWithYouNotice.State.skipped.rawValue
      try modelContext.save()
      return .skipped
    }

    try modelContext.save()
    return .retryScheduled(attemptCount: notice.attemptCount)
  }

  /// Crosses the at-most-once boundary before posting a system notice.
  ///
  /// `SWHighlightCenter.postNotice(for:)` has no acknowledgement. Persisting
  /// `attempted` first means a crash in the narrow interval before or during
  /// the call can lose one notice, but a relaunch cannot post a duplicate to a
  /// Messages thread.
  @discardableResult
  public func markAttempted(activityID: UUID, at date: Date) throws -> Bool {
    try withFreshCrossProcessState {
      try markAttemptedInCurrentContext(activityID: activityID, at: date)
    }
  }

  private func markAttemptedInCurrentContext(activityID: UUID, at date: Date) throws -> Bool {
    guard let notice = try fetchNotice(activityID: activityID), notice.state == .ready else {
      return false
    }

    notice.stateRawValue = PendingSharedWithYouNotice.State.attempted.rawValue
    notice.attemptedAt = date
    notice.lastAttemptAt = date
    try modelContext.save()
    return true
  }

  /// Removes a bounded number of terminal local-only delivery rows.
  ///
  /// The activity history remains intact; this deletes only the bookkeeping
  /// that prevents duplicate side effects. Retention separately removes both
  /// an Activity and any matching notice in one transaction.
  @discardableResult
  public func purgeTerminalNotices(limit: Int) throws -> Int {
    try withFreshCrossProcessState {
      try purgeTerminalNoticesInCurrentContext(limit: limit)
    }
  }

  private func purgeTerminalNoticesInCurrentContext(limit: Int) throws -> Int {
    guard limit > 0 else { return 0 }

    let notices = try modelContext.fetch(
      FetchDescriptor<PendingSharedWithYouNotice>(sortBy: [SortDescriptor(\.createdAt)])
    )
    let terminalNotices = notices.lazy.filter { notice in
      switch notice.state {
      case .attempted, .skipped:
        true
      case .waitingForActivityUpload, .ready, .unknown:
        false
      }
    }

    var removed = 0
    for notice in terminalNotices.prefix(limit) {
      modelContext.delete(notice)
      removed += 1
    }

    if removed > 0 {
      try modelContext.save()
    }
    return removed
  }

  private func fetchActivity(_ id: UUID) throws -> VaultActivity? {
    var descriptor = FetchDescriptor<VaultActivity>(predicate: #Predicate { $0.id == id })
    descriptor.fetchLimit = 1
    return try modelContext.fetch(descriptor).first
  }

  private func fetchNotice(activityID: UUID) throws -> PendingSharedWithYouNotice? {
    var descriptor = FetchDescriptor<PendingSharedWithYouNotice>(
      predicate: #Predicate { $0.activityID == activityID }
    )
    descriptor.fetchLimit = 1
    return try modelContext.fetch(descriptor).first
  }

  /// Refreshes this actor's long-lived context while holding the same
  /// per-vault transaction lock used by authored writes, sync acknowledgements,
  /// imports, and retention.
  ///
  /// The ready snapshot intentionally releases the lock before the potentially
  /// slow Shared with You lookup. A later `markAttempted` re-enters this helper
  /// and returns `false` if retention or a remote deletion removed the row in
  /// between, so a stale snapshot can never post a notice.
  private func withFreshCrossProcessState<Result>(
    _ operation: () throws -> Result
  ) throws -> Result {
    try authoredWriteCoordinator.withExclusiveAccess {
      modelContext.rollback()
      modelContext.processPendingChanges()
      return try operation()
    }
  }
}
