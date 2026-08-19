import Foundation
import SwiftData
import Testing

@testable import JournalVault

@Suite("Vault Shared with You notice store")
struct VaultSharedWithYouNoticeStoreTests {

  @Test("A root Activity maps to edit and a Reply maps to comment")
  func mapsActivityTopologyToNoticeChange() async throws {
    let store = try VaultContentStore.open(vaultID: VaultID(), layout: makeTemporaryLayout())
    let context = ModelContext(store.container)
    let rootEdgeID = UUID()
    let replyEdgeID = UUID()
    let rootActivity = VaultActivity(subjectEdgeID: rootEdgeID, rootEdgeID: rootEdgeID)
    let replyActivity = VaultActivity(subjectEdgeID: replyEdgeID, rootEdgeID: rootEdgeID)
    context.insert(rootActivity)
    context.insert(replyActivity)
    context.insert(
      PendingSharedWithYouNotice(
        activityID: rootActivity.id,
        state: .ready
      )
    )
    context.insert(
      PendingSharedWithYouNotice(
        activityID: replyActivity.id,
        state: .ready
      )
    )
    try context.save()

    let noticeStore = VaultSharedWithYouNoticeStore(store: store)
    let candidates = try await noticeStore.readyCandidates(limit: 10, now: .now)
    let changesByActivityID = Dictionary(
      uniqueKeysWithValues: candidates.map { ($0.activityID, $0.change) })

    #expect(changesByActivityID[rootActivity.id] == .edit)
    #expect(changesByActivityID[replyActivity.id] == .comment)
  }

  @Test("Excluding a processed page advances through sorted ready notices")
  func advancesBeyondExcludedReadyCandidates() async throws {
    let store = try VaultContentStore.open(vaultID: VaultID(), layout: makeTemporaryLayout())
    let context = ModelContext(store.container)
    var activityIDs: [UUID] = []

    for index in 0..<3 {
      let createdAt = Date(timeIntervalSince1970: TimeInterval(index))
      let activity = VaultActivity(
        subjectEdgeID: UUID(),
        rootEdgeID: UUID(),
        createdAt: createdAt
      )
      context.insert(activity)
      context.insert(
        PendingSharedWithYouNotice(
          activityID: activity.id,
          state: .ready,
          createdAt: createdAt
        )
      )
      activityIDs.append(activity.id)
    }
    try context.save()

    let noticeStore = VaultSharedWithYouNoticeStore(store: store)
    let firstPage = try await noticeStore.readyCandidates(limit: 2, now: .now)
    let secondPage = try await noticeStore.readyCandidates(
      limit: 2,
      excluding: Set(firstPage.map(\.activityID)),
      now: .now
    )

    #expect(firstPage.map(\.activityID) == Array(activityIDs.prefix(2)))
    #expect(secondPage.map(\.activityID) == [activityIDs[2]])
  }

  @Test("A transient lookup failure is persisted and bounded")
  func boundsTransientLookupFailures() async throws {
    let (store, activityID) = try makeReadyNoticeStore()
    let noticeStore = VaultSharedWithYouNoticeStore(store: store)
    let firstDate = Date(timeIntervalSince1970: 1)
    let secondDate = Date(timeIntervalSince1970: 2)
    let thirdDate = Date(timeIntervalSince1970: 3)

    #expect(
      try await noticeStore.recordTransientLookupFailure(
        activityID: activityID,
        maximumAttempts: 3,
        at: firstDate
      ) == .retryScheduled(attemptCount: 1)
    )
    #expect(
      try await noticeStore.recordTransientLookupFailure(
        activityID: activityID,
        maximumAttempts: 3,
        at: secondDate
      ) == .retryScheduled(attemptCount: 2)
    )

    let intermediateNotice = try fetchNotice(activityID: activityID, in: store)
    #expect(intermediateNotice?.state == .ready)
    #expect(intermediateNotice?.attemptCount == 2)
    #expect(intermediateNotice?.lastAttemptAt == secondDate)

    #expect(
      try await noticeStore.recordTransientLookupFailure(
        activityID: activityID,
        maximumAttempts: 3,
        at: thirdDate
      ) == .skipped
    )
    let skippedNotice = try fetchNotice(activityID: activityID, in: store)
    #expect(skippedNotice?.state == .skipped)
    #expect(skippedNotice?.attemptCount == 3)
    #expect(skippedNotice?.lastAttemptAt == thirdDate)
  }

  @Test("An attempted or skipped row is purged without deleting its Activity")
  func purgesOnlyTerminalLocalNoticeRows() async throws {
    let (store, activityID) = try makeReadyNoticeStore()
    let noticeStore = VaultSharedWithYouNoticeStore(store: store)
    #expect(try await noticeStore.markAttempted(activityID: activityID, at: .now))

    #expect(try await noticeStore.purgeTerminalNotices(limit: 1) == 1)
    #expect(try fetchNotice(activityID: activityID, in: store) == nil)
    #expect(try fetchActivity(id: activityID, in: store) != nil)
  }

  @Test("A notice removed after the ready snapshot cannot cross the post boundary")
  func doesNotAttemptAfterRetentionRemovesReadyNotice() async throws {
    let (store, activityID) = try makeReadyNoticeStore()
    let noticeStore = VaultSharedWithYouNoticeStore(store: store)
    let candidates = try await noticeStore.readyCandidates(limit: 1, now: .now)
    #expect(candidates.map(\.activityID) == [activityID])

    let context = ModelContext(store.container)
    let activity = try #require(
      try context.fetch(FetchDescriptor<VaultActivity>()).first { $0.id == activityID }
    )
    let notice = try #require(
      try context.fetch(FetchDescriptor<PendingSharedWithYouNotice>()).first {
        $0.activityID == activityID
      }
    )
    context.delete(activity)
    context.delete(notice)
    try context.save()

    #expect(try await noticeStore.markAttempted(activityID: activityID, at: .now) == false)
  }

  @Test("Ready notice events are independently broadcast from local mutations")
  func broadcastsReadyNoticeVaultID() async {
    let registry = VaultStoreRegistry(layout: makeTemporaryLayout())
    let vaultID = VaultID()
    let stream = registry.readySharedWithYouNotices()
    let receivedVaultID = Task { () -> VaultID? in
      for await receivedVaultID in stream {
        return receivedVaultID
      }
      return nil
    }

    registry.notifySharedWithYouNoticeReady(for: vaultID)

    #expect(await receivedVaultID.value == vaultID)
  }

  private func makeReadyNoticeStore() throws -> (VaultContentStore, UUID) {
    let store = try VaultContentStore.open(vaultID: VaultID(), layout: makeTemporaryLayout())
    let activity = VaultActivity(subjectEdgeID: UUID(), rootEdgeID: UUID())
    let context = ModelContext(store.container)
    context.insert(activity)
    context.insert(PendingSharedWithYouNotice(activityID: activity.id, state: .ready))
    try context.save()
    return (store, activity.id)
  }

  private func fetchNotice(
    activityID: UUID,
    in store: VaultContentStore
  ) throws -> PendingSharedWithYouNotice? {
    let context = ModelContext(store.container)
    return try context.fetch(FetchDescriptor<PendingSharedWithYouNotice>()).first {
      $0.activityID == activityID
    }
  }

  private func fetchActivity(
    id: UUID,
    in store: VaultContentStore
  ) throws -> VaultActivity? {
    let context = ModelContext(store.container)
    return try context.fetch(FetchDescriptor<VaultActivity>()).first { $0.id == id }
  }
}
