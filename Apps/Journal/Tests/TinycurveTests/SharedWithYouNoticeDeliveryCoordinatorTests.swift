import Foundation
import JournalVault
import SwiftData
import Testing

@testable import Tinycurve

@Suite("Shared with You notice delivery")
@MainActor
struct SharedWithYouNoticeDeliveryCoordinatorTests {

  @Test("Posts a root Activity as edit and a Reply Activity as comment")
  func mapsRootAndReplyAfterReadyAcknowledgement() async throws {
    let fixture = try makeFixture()
    let rootEdgeID = UUID()
    _ = try insertReadyNotice(
      into: fixture.store,
      subjectEdgeID: rootEdgeID,
      rootEdgeID: rootEdgeID
    )
    _ = try insertReadyNotice(
      into: fixture.store,
      subjectEdgeID: UUID(),
      rootEdgeID: rootEdgeID
    )
    let client = FakeSharedWithYouHighlightClient()
    let coordinator = SharedWithYouNoticeDeliveryCoordinator(
      runtime: fixture.runtime,
      highlightClient: client
    )

    await coordinator.drain(vaultID: fixture.vaultID)

    #expect(client.postedChanges == [.edit, .comment])
    #expect(try noticeCount(in: fixture.store) == 0)
  }

  @Test("An imported Activity without a local origin intent never posts")
  func doesNotPostRemoteImportedActivity() async throws {
    let fixture = try makeFixture()
    let context = ModelContext(fixture.store.container)
    context.insert(VaultActivity(subjectEdgeID: UUID(), rootEdgeID: UUID()))
    try context.save()
    let client = FakeSharedWithYouHighlightClient()
    let coordinator = SharedWithYouNoticeDeliveryCoordinator(
      runtime: fixture.runtime,
      highlightClient: client
    )

    await coordinator.drain(vaultID: fixture.vaultID)

    #expect(client.postedChanges.isEmpty)
    #expect(try noticeCount(in: fixture.store) == 0)
  }

  @Test("Startup, active-scene recovery, and ready events each drain pending rows")
  func drainsAcrossAllAppLifecyclePaths() async throws {
    let fixture = try makeFixture()
    let rootEdgeID = UUID()
    _ = try insertReadyNotice(
      into: fixture.store,
      subjectEdgeID: rootEdgeID,
      rootEdgeID: rootEdgeID
    )
    let client = FakeSharedWithYouHighlightClient()
    let coordinator = SharedWithYouNoticeDeliveryCoordinator(
      runtime: fixture.runtime,
      highlightClient: client
    )

    let initialSceneID = UUID()
    await coordinator.start(sceneID: initialSceneID, isSceneActive: true)
    #expect(client.postedChanges == [.edit])

    _ = try insertReadyNotice(
      into: fixture.store,
      subjectEdgeID: UUID(),
      rootEdgeID: rootEdgeID
    )
    coordinator.sceneDidBecomeInactive(initialSceneID)
    await coordinator.sceneDidBecomeActive(UUID())
    #expect(client.postedChanges == [.edit, .comment])

    _ = try insertReadyNotice(
      into: fixture.store,
      subjectEdgeID: rootEdgeID,
      rootEdgeID: rootEdgeID
    )
    fixture.runtime.emitReadyNotice(for: fixture.vaultID)
    await waitUntil { client.postedChanges.count == 3 }

    #expect(client.postedChanges == [.edit, .comment, .edit])
  }

  @Test("Startup recovery drains ready notices beyond one bounded batch")
  func drainsEveryReadyNoticeAtStartup() async throws {
    let fixture = try makeFixture()
    let expectedNoticeCount = SharedWithYouNoticeDeliveryCoordinator.drainBatchSize + 1
    for index in 0..<expectedNoticeCount {
      _ = try insertReadyNotice(
        into: fixture.store,
        subjectEdgeID: UUID(),
        rootEdgeID: UUID(),
        createdAt: Date(timeIntervalSince1970: TimeInterval(index))
      )
    }
    let client = FakeSharedWithYouHighlightClient()
    let coordinator = SharedWithYouNoticeDeliveryCoordinator(
      runtime: fixture.runtime,
      highlightClient: client
    )

    await coordinator.start(sceneID: UUID(), isSceneActive: true)

    #expect(client.lookupURLs.count == expectedNoticeCount)
    #expect(client.postedChanges.count == expectedNoticeCount)
    #expect(try readyNoticeCount(in: fixture.store) == 0)
  }

  @Test("A ready event after an empty snapshot redrains before its owner releases")
  func coalescesLateReadyEventBeforeReleasingVaultDrain() async throws {
    let fixture = try makeFixture()
    let rootEdgeID = UUID()
    _ = try insertReadyNotice(
      into: fixture.store,
      subjectEdgeID: rootEdgeID,
      rootEdgeID: rootEdgeID
    )
    let client = FakeSharedWithYouHighlightClient()
    var injectedLateNotice = false
    let coordinator = SharedWithYouNoticeDeliveryCoordinator(
      runtime: fixture.runtime,
      highlightClient: client,
      yieldAfterEmptyReadySnapshot: {
        guard injectedLateNotice == false else {
          await Task.yield()
          return
        }

        injectedLateNotice = true
        _ = try? self.insertReadyNotice(
          into: fixture.store,
          subjectEdgeID: UUID(),
          rootEdgeID: rootEdgeID
        )
        fixture.runtime.emitReadyNotice(for: fixture.vaultID)
        await Task.yield()
      }
    )

    await coordinator.start(sceneID: UUID(), isSceneActive: true)
    await waitUntil { client.postedChanges.count == 2 }

    #expect(injectedLateNotice)
    #expect(client.postedChanges == [.edit, .comment])
    #expect(try readyNoticeCount(in: fixture.store) == 0)
  }

  @Test("Repeated starts and rapid active scenes do not consume a retry twice")
  func coalescesStartupAndInitialSceneActivation() async throws {
    let fixture = try makeFixture()
    let activityID = try insertReadyNotice(
      into: fixture.store,
      subjectEdgeID: UUID(),
      rootEdgeID: UUID()
    )
    let client = FakeSharedWithYouHighlightClient()
    client.lookupResult = .failure
    let coordinator = SharedWithYouNoticeDeliveryCoordinator(
      runtime: fixture.runtime,
      highlightClient: client
    )

    let firstSceneID = UUID()
    let secondSceneID = UUID()
    await coordinator.start(sceneID: firstSceneID, isSceneActive: true)
    await coordinator.start(sceneID: secondSceneID, isSceneActive: true)
    await coordinator.sceneDidBecomeActive(firstSceneID)
    await coordinator.sceneDidBecomeActive(secondSceneID)

    #expect(client.lookupURLs.count == 1)
    #expect(try notice(activityID: activityID, in: fixture.store)?.attemptCount == 1)
  }

  @Test("A real foreground return drains notices made ready while inactive")
  func drainsAfterInitiallyActiveSceneBecomesInactive() async throws {
    let fixture = try makeFixture()
    let client = FakeSharedWithYouHighlightClient()
    client.lookupResult = .failure
    let coordinator = SharedWithYouNoticeDeliveryCoordinator(
      runtime: fixture.runtime,
      highlightClient: client
    )
    let initialSceneID = UUID()

    await coordinator.start(sceneID: initialSceneID, isSceneActive: true)
    coordinator.sceneDidBecomeInactive(initialSceneID)

    let activityID = try insertReadyNotice(
      into: fixture.store,
      subjectEdgeID: UUID(),
      rootEdgeID: UUID()
    )
    await coordinator.sceneDidBecomeActive(UUID())

    #expect(client.lookupURLs.count == 1)
    #expect(try notice(activityID: activityID, in: fixture.store)?.attemptCount == 1)
  }

  @Test("An initially inactive start waits for the first active recovery")
  func waitsForInitialActiveSceneBeforeRetrying() async throws {
    let fixture = try makeFixture()
    let activityID = try insertReadyNotice(
      into: fixture.store,
      subjectEdgeID: UUID(),
      rootEdgeID: UUID()
    )
    let client = FakeSharedWithYouHighlightClient()
    client.lookupResult = .failure
    let coordinator = SharedWithYouNoticeDeliveryCoordinator(
      runtime: fixture.runtime,
      highlightClient: client
    )
    let sceneID = UUID()

    await coordinator.start(sceneID: sceneID, isSceneActive: false)
    #expect(client.lookupURLs.isEmpty)

    await coordinator.sceneDidBecomeActive(sceneID)

    #expect(client.lookupURLs.count == 1)
    #expect(try notice(activityID: activityID, in: fixture.store)?.attemptCount == 1)
  }

  @Test("Unsupported system, missing share URL, and absent highlight skip terminally")
  func skipsNonDeliverableNotices() async throws {
    let unsupported = try makeFixture()
    _ = try insertReadyNotice(into: unsupported.store, subjectEdgeID: UUID(), rootEdgeID: UUID())
    let unsupportedClient = FakeSharedWithYouHighlightClient()
    unsupportedClient.isSystemCollaborationSupportAvailable = false
    await SharedWithYouNoticeDeliveryCoordinator(
      runtime: unsupported.runtime,
      highlightClient: unsupportedClient
    ).drain(vaultID: unsupported.vaultID)
    #expect(unsupportedClient.lookupURLs.isEmpty)
    #expect(try noticeCount(in: unsupported.store) == 0)

    let missingURL = try makeFixture(shareURL: nil)
    _ = try insertReadyNotice(into: missingURL.store, subjectEdgeID: UUID(), rootEdgeID: UUID())
    let missingURLClient = FakeSharedWithYouHighlightClient()
    await SharedWithYouNoticeDeliveryCoordinator(
      runtime: missingURL.runtime,
      highlightClient: missingURLClient
    ).drain(vaultID: missingURL.vaultID)
    #expect(missingURLClient.lookupURLs.isEmpty)
    #expect(try noticeCount(in: missingURL.store) == 0)

    let absentHighlight = try makeFixture()
    _ = try insertReadyNotice(
      into: absentHighlight.store,
      subjectEdgeID: UUID(),
      rootEdgeID: UUID()
    )
    let absentHighlightClient = FakeSharedWithYouHighlightClient()
    absentHighlightClient.lookupResult = .absent
    await SharedWithYouNoticeDeliveryCoordinator(
      runtime: absentHighlight.runtime,
      highlightClient: absentHighlightClient
    ).drain(vaultID: absentHighlight.vaultID)
    #expect(absentHighlightClient.lookupURLs.count == 1)
    #expect(absentHighlightClient.postedChanges.isEmpty)
    #expect(try noticeCount(in: absentHighlight.store) == 0)
  }

  @Test("Transient highlight failures persist a retry budget without same-drain looping")
  func boundsTransientHighlightLookupRetry() async throws {
    let fixture = try makeFixture()
    let activityID = try insertReadyNotice(
      into: fixture.store,
      subjectEdgeID: UUID(),
      rootEdgeID: UUID()
    )
    let client = FakeSharedWithYouHighlightClient()
    client.lookupResult = .failure
    let coordinator = SharedWithYouNoticeDeliveryCoordinator(
      runtime: fixture.runtime,
      highlightClient: client
    )

    await coordinator.drain(vaultID: fixture.vaultID)
    #expect(client.lookupURLs.count == 1)
    #expect(try notice(activityID: activityID, in: fixture.store)?.attemptCount == 1)

    await coordinator.drain(vaultID: fixture.vaultID)
    #expect(client.lookupURLs.count == 2)
    #expect(try notice(activityID: activityID, in: fixture.store)?.attemptCount == 2)

    await coordinator.drain(vaultID: fixture.vaultID)
    #expect(client.lookupURLs.count == 3)
    #expect(try notice(activityID: activityID, in: fixture.store) == nil)
    #expect(client.postedChanges.isEmpty)
  }

  @Test("Attempted state is durable before post and terminal rows never repost")
  func persistsAtMostOnceBoundaryBeforePosting() async throws {
    let fixture = try makeFixture()
    let activityID = try insertReadyNotice(
      into: fixture.store,
      subjectEdgeID: UUID(),
      rootEdgeID: UUID()
    )
    let client = FakeSharedWithYouHighlightClient()
    var stateAtPost: PendingSharedWithYouNotice.State?
    client.onPost = {
      stateAtPost = try? Self.notice(activityID: activityID, in: fixture.store)?.state
    }
    let coordinator = SharedWithYouNoticeDeliveryCoordinator(
      runtime: fixture.runtime,
      highlightClient: client
    )

    await coordinator.drain(vaultID: fixture.vaultID)
    await coordinator.drain(vaultID: fixture.vaultID)

    #expect(stateAtPost == .attempted)
    #expect(client.postedChanges.count == 1)
    #expect(try notice(activityID: activityID, in: fixture.store) == nil)
  }

  @Test("A retention deletion between lookup and attempted state does not post")
  func doesNotPostWhenRetentionWinsAfterReadySnapshot() async throws {
    let fixture = try makeFixture()
    let activityID = try insertReadyNotice(
      into: fixture.store,
      subjectEdgeID: UUID(),
      rootEdgeID: UUID()
    )
    let client = FakeSharedWithYouHighlightClient()
    client.beforeReturningHighlight = {
      let context = ModelContext(fixture.store.container)
      let activity = try #require(
        try context.fetch(FetchDescriptor<VaultActivity>()).first { $0.id == activityID }
      )
      let pendingNotice = try #require(
        try context.fetch(FetchDescriptor<PendingSharedWithYouNotice>()).first {
          $0.activityID == activityID
        }
      )
      context.delete(activity)
      context.delete(pendingNotice)
      try context.save()
    }
    let coordinator = SharedWithYouNoticeDeliveryCoordinator(
      runtime: fixture.runtime,
      highlightClient: client
    )

    await coordinator.drain(vaultID: fixture.vaultID)

    #expect(client.postedChanges.isEmpty)
    #expect(try notice(activityID: activityID, in: fixture.store) == nil)
  }

  private func makeFixture(shareURL: URL? = URL(string: "https://icloud.example/vault")) throws
    -> NoticeFixture
  {
    let vaultID = VaultID()
    let store = try VaultContentStore.open(vaultID: vaultID, layout: temporaryLayout())
    let descriptor = VaultDescriptor(
      vaultID: vaultID,
      title: "Shared Vault",
      ownership: .owned,
      isShared: true,
      shareURL: shareURL,
      participantCount: 2
    )
    let noticeStore = VaultSharedWithYouNoticeStore(store: store)
    let runtime = FakeSharedWithYouNoticeRuntime(
      descriptors: [vaultID: descriptor],
      noticeStores: [vaultID: noticeStore]
    )
    return NoticeFixture(vaultID: vaultID, store: store, runtime: runtime)
  }

  private func insertReadyNotice(
    into store: VaultContentStore,
    subjectEdgeID: UUID?,
    rootEdgeID: UUID?,
    createdAt: Date = Date()
  ) throws -> UUID {
    let activity = VaultActivity(
      subjectEdgeID: subjectEdgeID,
      rootEdgeID: rootEdgeID,
      createdAt: createdAt
    )
    let context = ModelContext(store.container)
    context.insert(activity)
    context.insert(
      PendingSharedWithYouNotice(
        activityID: activity.id,
        state: .ready,
        createdAt: createdAt
      )
    )
    try context.save()
    return activity.id
  }

  private static func notice(
    activityID: UUID,
    in store: VaultContentStore
  ) throws -> PendingSharedWithYouNotice? {
    let context = ModelContext(store.container)
    return try context.fetch(FetchDescriptor<PendingSharedWithYouNotice>()).first {
      $0.activityID == activityID
    }
  }

  private func notice(
    activityID: UUID,
    in store: VaultContentStore
  ) throws -> PendingSharedWithYouNotice? {
    try Self.notice(activityID: activityID, in: store)
  }

  private func noticeCount(in store: VaultContentStore) throws -> Int {
    let context = ModelContext(store.container)
    return try context.fetchCount(FetchDescriptor<PendingSharedWithYouNotice>())
  }

  private func readyNoticeCount(in store: VaultContentStore) throws -> Int {
    let readyRawValue = PendingSharedWithYouNotice.State.ready.rawValue
    let descriptor = FetchDescriptor<PendingSharedWithYouNotice>(
      predicate: #Predicate { $0.stateRawValue == readyRawValue }
    )
    let context = ModelContext(store.container)
    return try context.fetchCount(descriptor)
  }

  private func temporaryLayout() -> VaultStoreLayout {
    VaultStoreLayout(
      rootDirectoryURL: FileManager.default.temporaryDirectory.appending(
        path: "TinycurveSharedWithYouTests-\(UUID().uuidString)",
        directoryHint: .isDirectory
      )
    )
  }

  private func waitUntil(
    _ condition: @escaping @MainActor () -> Bool
  ) async {
    for _ in 0..<100 where condition() == false {
      await Task.yield()
    }
  }
}

private struct NoticeFixture {
  let vaultID: VaultID
  let store: VaultContentStore
  let runtime: FakeSharedWithYouNoticeRuntime
}

@MainActor
private final class FakeSharedWithYouNoticeRuntime: SharedWithYouNoticeRuntime {

  let descriptors: [VaultID: VaultDescriptor]
  let noticeStores: [VaultID: VaultSharedWithYouNoticeStore]
  private var continuation: AsyncStream<VaultID>.Continuation?
  private(set) var postedVaultIDs: [VaultID] = []

  init(
    descriptors: [VaultID: VaultDescriptor],
    noticeStores: [VaultID: VaultSharedWithYouNoticeStore]
  ) {
    self.descriptors = descriptors
    self.noticeStores = noticeStores
  }

  var sharedWithYouNoticeVaultIDs: [VaultID] {
    Array(descriptors.keys)
  }

  func sharedWithYouNoticeDescriptor(for vaultID: VaultID) -> VaultDescriptor? {
    descriptors[vaultID]
  }

  func sharedWithYouNoticeStore(for vaultID: VaultID) throws -> VaultSharedWithYouNoticeStore {
    guard let store = noticeStores[vaultID] else {
      throw NoticeRuntimeError.missingStore
    }
    return store
  }

  func readySharedWithYouNoticeVaults() -> AsyncStream<VaultID> {
    AsyncStream { continuation in
      self.continuation = continuation
    }
  }

  func noteSharedWithYouNoticePosted(for vaultID: VaultID, at date: Date) {
    postedVaultIDs.append(vaultID)
  }

  func emitReadyNotice(for vaultID: VaultID) {
    continuation?.yield(vaultID)
  }

  private enum NoticeRuntimeError: Error {
    case missingStore
  }
}

@MainActor
private final class FakeSharedWithYouHighlightClient: SharedWithYouHighlightClient {

  enum LookupResult {
    case highlight
    case absent
    case failure
  }

  var isSystemCollaborationSupportAvailable = true
  var lookupResult: LookupResult = .highlight
  var beforeReturningHighlight: (@MainActor () throws -> Void)?
  var onPost: (@MainActor () -> Void)?
  private(set) var lookupURLs: [URL] = []
  private(set) var postedChanges: [VaultSharedWithYouNoticeChange] = []

  func getCollaborationHighlight(
    for shareURL: URL
  ) async throws -> SharedWithYouNoticeHighlight? {
    lookupURLs.append(shareURL)
    try beforeReturningHighlight?()

    switch lookupResult {
    case .highlight:
      return SharedWithYouNoticeHighlight { [weak self] change in
        self?.onPost?()
        self?.postedChanges.append(change)
      }
    case .absent:
      return nil
    case .failure:
      throw HighlightLookupError.transient
    }
  }

  private enum HighlightLookupError: Error {
    case transient
  }
}
