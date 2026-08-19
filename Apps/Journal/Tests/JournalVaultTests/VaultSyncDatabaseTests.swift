import CloudKit
import Foundation
import SwiftData
import Testing

@testable import JournalVault

struct VaultSyncDatabaseTests {

  @MainActor
  private func makeStoreWithCard() throws -> (store: VaultContentStore, cardID: UUID) {
    let store = try VaultContentStore.open(vaultID: VaultID(), layout: makeTemporaryLayout())
    let edges = try store.createThread(cards: [.init(kind: .text, text: "hello")])
    return (store, edges[0].cardID)
  }

  @MainActor
  private func makeStoreWithParticipantActivity() throws -> (
    store: VaultContentStore,
    activityID: UUID
  ) {
    let store = try VaultContentStore.open(vaultID: VaultID(), layout: makeTemporaryLayout())
    _ = try store.createThread(
      cards: [.init(kind: .text, text: "hello participants")],
      deliveryPolicy: .notifyParticipants
    )
    let activity = try #require(
      try store.container.mainContext.fetch(FetchDescriptor<VaultActivity>()).first
    )
    return (store, activity.id)
  }

  @MainActor
  private func makeStoreWithSubtreeAndMedia() throws -> (
    store: VaultContentStore,
    rootEdgeID: UUID,
    attachmentFileURL: URL
  ) {
    let store = try VaultContentStore.open(vaultID: VaultID(), layout: makeTemporaryLayout())
    let edges = try store.createThread(cards: [
      .init(kind: .text, text: "root"),
      .init(kind: .photo, mediaData: Data([0x01, 0x02])),
    ])
    let attachment = try #require(
      try store.container.mainContext.fetch(FetchDescriptor<JournalVault.Attachment>()).first
    )
    let resource = try #require(
      try store.container.mainContext.fetch(FetchDescriptor<JournalVault.AttachmentResource>())
        .first
    )
    #expect(attachment.primaryResourceID == resource.id)
    return (store, edges[0].id, store.fileURL(for: resource))
  }

  private func fetchPendingMutation(
    recordName: String,
    in store: VaultContentStore
  ) throws -> PendingMutation? {
    let context = ModelContext(store.container)
    return try context.fetch(FetchDescriptor<PendingMutation>())
      .first { $0.recordName == recordName }
  }

  // MARK: - Outgoing

  @Test
  func makeRecord_populatesFieldsAndStagesPendingRow() async throws {
    let (store, cardID) = try await makeStoreWithCard()
    let database = VaultSyncDatabase(store: store)

    let record = try await database.makeRecord(
      recordName: cardID.uuidString,
      zoneID: store.vaultID.zoneID()
    )

    #expect(record?.recordType == VaultRecordType.card.rawValue)
    #expect(record?[VaultRecordMapper.CardKey.body] as? String == "hello")

    let pending = try fetchPendingMutation(recordName: cardID.uuidString, in: store)
    #expect(pending?.stagedAt != nil)
  }

  @Test
  func handleSavedRecord_clearsOutboxAndStoresMetadata() async throws {
    let (store, cardID) = try await makeStoreWithCard()
    let database = VaultSyncDatabase(store: store)
    let record = try #require(
      try await database.makeRecord(recordName: cardID.uuidString, zoneID: store.vaultID.zoneID())
    )

    try await database.handleSavedRecord(record)

    #expect(try fetchPendingMutation(recordName: cardID.uuidString, in: store) == nil)

    let context = ModelContext(store.container)
    let metadata = try context.fetch(FetchDescriptor<SyncMetadata>())
      .first { $0.recordName == cardID.uuidString }
    #expect(metadata != nil)
    #expect(metadata?.recordType == VaultRecordType.card.rawValue)
  }

  @Test
  func handleSavedRecord_keepsRowThatWasReEnqueuedInFlight() async throws {
    let (store, cardID) = try await makeStoreWithCard()
    let database = VaultSyncDatabase(store: store)
    let record = try #require(
      try await database.makeRecord(recordName: cardID.uuidString, zoneID: store.vaultID.zoneID())
    )

    // The user edits while the upload is in flight: the row re-arms.
    try await MainActor.run {
      try store.updateCardBody(cardID: cardID, body: "edited mid-flight")
    }

    try await database.handleSavedRecord(record)

    // The newer state must still be pending — the edit is not lost.
    let pending = try fetchPendingMutation(recordName: cardID.uuidString, in: store)
    #expect(pending?.kind == .save)
  }

  @Test
  func handleServerRecordChanged_adoptsServerMetadataAndKeepsPending() async throws {
    let (store, cardID) = try await makeStoreWithCard()
    let database = VaultSyncDatabase(store: store)
    _ = try await database.makeRecord(
      recordName: cardID.uuidString,
      zoneID: store.vaultID.zoneID()
    )

    // The server holds a newer record for the same ID.
    let serverRecord = CKRecord(
      recordType: VaultRecordType.card.rawValue,
      recordID: CKRecord.ID(recordName: cardID.uuidString, zoneID: store.vaultID.zoneID())
    )
    try await database.handleServerRecordChanged(serverRecord: serverRecord)

    // Local wins: the pending save survives (unstaged, ready to re-send) and
    // the server's system fields are on file for the retry.
    let pending = try fetchPendingMutation(recordName: cardID.uuidString, in: store)
    #expect(pending?.kind == .save)
    #expect(pending?.stagedAt == nil)

    let context = ModelContext(store.container)
    let metadata = try context.fetch(FetchDescriptor<SyncMetadata>())
      .first { $0.recordName == cardID.uuidString }
    #expect(metadata != nil)
  }

  @Test
  func pendingChanges_ordersContentThenActivityThenPulse() async throws {
    let (store, _) = try await makeStoreWithParticipantActivity()
    let database = VaultSyncDatabase(store: store)

    let changes = try await database.pendingChanges()

    #expect(changes.map(\.recordType) == [.card, .cardEdge, .activity, .notificationPulse])
  }

  @Test
  func makeRecord_transportsActivityAndFixedPulse() async throws {
    let (store, activityID) = try await makeStoreWithParticipantActivity()
    let database = VaultSyncDatabase(store: store)

    let activityRecord = try #require(
      try await database.makeRecord(
        recordName: activityID.uuidString,
        zoneID: store.vaultID.zoneID()
      )
    )
    let pulseRecord = try #require(
      try await database.makeRecord(
        recordName: VaultNotificationPulse.fixedRecordName,
        zoneID: store.vaultID.zoneID()
      )
    )

    #expect(activityRecord.recordType == VaultRecordType.activity.rawValue)
    #expect(activityRecord.recordID.recordName == activityID.uuidString)
    #expect(
      activityRecord[VaultRecordMapper.VaultActivityKey.kindRawValue] as? String == "contentAdded"
    )
    #expect(activityRecord[VaultRecordMapper.VaultActivityKey.createdAt] is Date)
    #expect(pulseRecord.recordType == VaultRecordType.notificationPulse.rawValue)
    #expect(pulseRecord.recordID.recordName == VaultNotificationPulse.fixedRecordName)
    #expect(
      pulseRecord[VaultRecordMapper.VaultNotificationPulseKey.latestActivityRecordName] as? String
        == activityID.uuidString
    )
  }

  @MainActor
  @Test
  func handleSavedRecord_doesNotConsumePulseRearmedByAnotherStore() async throws {
    let layout = makeTemporaryLayout()
    let vaultID = VaultID()
    let syncStore = try VaultContentStore.open(vaultID: vaultID, layout: layout)
    _ = try syncStore.createThread(
      cards: [.init(kind: .text, text: "first")],
      deliveryPolicy: .notifyParticipants
    )
    let database = VaultSyncDatabase(store: syncStore)
    let inFlightPulse = try #require(
      try await database.makeRecord(
        recordName: VaultNotificationPulse.fixedRecordName,
        zoneID: vaultID.zoneID()
      )
    )

    // Model a Share extension/App Intent process with an independently opened
    // container. Its authored transaction must win over the older Pulse ACK.
    let writerStore = try VaultContentStore.open(vaultID: vaultID, layout: layout)
    _ = try writerStore.createThread(
      cards: [.init(kind: .text, text: "second")],
      deliveryPolicy: .notifyParticipants
    )

    try await database.handleSavedRecord(inFlightPulse)

    let verificationContext = ModelContext(writerStore.container)
    let pendingPulse = try verificationContext.fetch(FetchDescriptor<PendingMutation>())
      .first { $0.recordName == VaultNotificationPulse.fixedRecordName }
    #expect(pendingPulse?.kind == .save)
    #expect(pendingPulse?.stagedAt == nil)
  }

  @MainActor
  @Test
  func importChanges_preservesPulseAuthoredByAnotherStore() async throws {
    let layout = makeTemporaryLayout()
    let vaultID = VaultID()
    let syncStore = try VaultContentStore.open(vaultID: vaultID, layout: layout)
    let database = VaultSyncDatabase(store: syncStore)
    _ = try await database.importChanges(modifications: [], deletions: [])

    let writerStore = try VaultContentStore.open(
      vaultID: vaultID,
      layout: layout,
      recoveryPolicy: .failWithoutReset
    )
    _ = try writerStore.createThread(
      cards: [.init(kind: .text, text: "local extension write")],
      deliveryPolicy: .notifyParticipants
    )
    let locallyAuthoredPulse = try #require(
      try writerStore.container.mainContext.fetch(FetchDescriptor<VaultNotificationPulse>()).first
    )
    let localActivityRecordName = locallyAuthoredPulse.latestActivityRecordName
    let remotePulse = VaultNotificationPulse(
      latestActivityRecordName: UUID().uuidString,
      kind: .contentAdded,
      updatedAt: Date(timeIntervalSince1970: 10)
    )
    let remoteRecord = CKRecord(
      recordType: VaultRecordType.notificationPulse.rawValue,
      recordID: CKRecord.ID(
        recordName: VaultNotificationPulse.fixedRecordName,
        zoneID: vaultID.zoneID()
      )
    )
    VaultRecordMapper.applyFields(of: remotePulse, to: remoteRecord)

    let outcome = try await database.importChanges(
      modifications: [remoteRecord],
      deletions: []
    )

    let verificationStore = try VaultContentStore.open(
      vaultID: vaultID,
      layout: layout,
      recoveryPolicy: .failWithoutReset
    )
    let context = verificationStore.container.mainContext
    let pulse = try #require(
      try context.fetch(FetchDescriptor<VaultNotificationPulse>()).first
    )
    #expect(outcome.skippedConflictCount == 1)
    #expect(outcome.importedRecordCount == 0)
    #expect(pulse.latestActivityRecordName == localActivityRecordName)
    #expect(try context.fetchCount(FetchDescriptor<VaultNotificationPulse>()) == 1)
    #expect(
      try context.fetch(FetchDescriptor<PendingMutation>())
        .contains { $0.recordName == VaultNotificationPulse.fixedRecordName }
    )
  }

  @Test
  func handleSavedRecord_activityAcknowledgementAdvancesOnlyMatchingWaitingNotice() async throws {
    let (store, activityID) = try await makeStoreWithParticipantActivity()
    let database = VaultSyncDatabase(store: store)
    let activityRecord = try #require(
      try await database.makeRecord(
        recordName: activityID.uuidString,
        zoneID: store.vaultID.zoneID()
      )
    )

    let context = ModelContext(store.container)
    let unrelatedActivityID = UUID()
    let unrelatedNotice = PendingSharedWithYouNotice(activityID: unrelatedActivityID)
    context.insert(unrelatedNotice)
    try context.save()

    let firstOutcome = try await database.handleSavedRecord(activityRecord)
    #expect(firstOutcome.didAcknowledgeLocalActivity)
    #expect(firstOutcome.didMakeSharedWithYouNoticeReady)

    let matchingNotice = try #require(
      try context.fetch(FetchDescriptor<PendingSharedWithYouNotice>()).first {
        $0.activityID == activityID
      }
    )
    #expect(matchingNotice.state == .ready)
    #expect(unrelatedNotice.state == .waitingForActivityUpload)

    matchingNotice.stateRawValue = PendingSharedWithYouNotice.State.attempted.rawValue
    try context.save()
    let duplicateOutcome = try await database.handleSavedRecord(activityRecord)
    #expect(!duplicateOutcome.didAcknowledgeLocalActivity)
    #expect(!duplicateOutcome.didMakeSharedWithYouNoticeReady)

    #expect(matchingNotice.state == .attempted)
  }

  @Test
  func handleServerRecordChanged_pulseKeepsLocalWinsAndRearmsSingleton() async throws {
    let (store, activityID) = try await makeStoreWithParticipantActivity()
    let database = VaultSyncDatabase(store: store)
    _ = try await database.makeRecord(
      recordName: VaultNotificationPulse.fixedRecordName,
      zoneID: store.vaultID.zoneID()
    )

    let serverRecord = CKRecord(
      recordType: VaultRecordType.notificationPulse.rawValue,
      recordID: CKRecord.ID(
        recordName: VaultNotificationPulse.fixedRecordName,
        zoneID: store.vaultID.zoneID()
      )
    )
    let latestActivityRecordNameKey =
      VaultRecordMapper.VaultNotificationPulseKey.latestActivityRecordName
    serverRecord[latestActivityRecordNameKey] = UUID().uuidString
    serverRecord[VaultRecordMapper.VaultNotificationPulseKey.kindRawValue] = "futureActivityKind"
    serverRecord[VaultRecordMapper.VaultNotificationPulseKey.updatedAt] = Date()

    try await database.handleServerRecordChanged(serverRecord: serverRecord)

    let pending = try #require(
      try fetchPendingMutation(
        recordName: VaultNotificationPulse.fixedRecordName,
        in: store
      )
    )
    let context = ModelContext(store.container)
    let pulse = try #require(
      try context.fetch(FetchDescriptor<VaultNotificationPulse>()).first
    )
    #expect(pending.recordType == VaultRecordType.notificationPulse.rawValue)
    #expect(pending.kind == .save)
    #expect(pending.stagedAt == nil)
    #expect(pulse.latestActivityRecordName == activityID.uuidString)
  }

  @Test
  func makeRecord_unknownOutboxTypeKeepsDurableRowButDoesNotScheduleIt() async throws {
    let store = try VaultContentStore.open(vaultID: VaultID(), layout: makeTemporaryLayout())
    let database = VaultSyncDatabase(store: store)
    let context = ModelContext(store.container)
    context.insert(
      PendingMutation(
        recordName: "future-record",
        recordType: "FutureVaultRecord",
        kind: .save
      )
    )
    try context.save()

    let record = try await database.makeRecord(
      recordName: "future-record",
      zoneID: store.vaultID.zoneID()
    )

    #expect(record == nil)
    #expect(try fetchPendingMutation(recordName: "future-record", in: store) != nil)
    #expect(try await database.pendingChanges().isEmpty)
    #expect(try await database.hasPendingMutations() == false)
  }

  @Test
  func unknownOutboxDelete_isRemovedFromStaleEngineBatchButRetainedDurably() async throws {
    let store = try VaultContentStore.open(vaultID: VaultID(), layout: makeTemporaryLayout())
    let database = VaultSyncDatabase(store: store)
    let context = ModelContext(store.container)
    let unknownRecordID = CKRecord.ID(recordName: "future-record", zoneID: store.vaultID.zoneID())
    let knownRecordID = CKRecord.ID(recordName: UUID().uuidString, zoneID: store.vaultID.zoneID())
    let staleRecordID = CKRecord.ID(recordName: UUID().uuidString, zoneID: store.vaultID.zoneID())
    context.insert(
      PendingMutation(
        recordName: unknownRecordID.recordName,
        recordType: "FutureVaultRecord",
        kind: .delete
      )
    )
    context.insert(
      PendingMutation(
        recordName: knownRecordID.recordName,
        recordType: VaultRecordType.card.rawValue,
        kind: .delete
      )
    )
    try context.save()

    #expect(
      try await database.hasUnknownDeletePendingMutation(recordName: unknownRecordID.recordName)
    )
    #expect(
      try await database.hasUnknownDeletePendingMutation(
        recordName: knownRecordID.recordName
      ) == false
    )
    let scheduledChanges = try await database.pendingChanges()
    #expect(scheduledChanges.map(\.recordName) == [knownRecordID.recordName])

    let staleEngineBatch: [CKSyncEngine.PendingRecordZoneChange] = [
      .deleteRecord(unknownRecordID),
      .deleteRecord(knownRecordID),
      .deleteRecord(staleRecordID),
      .saveRecord(unknownRecordID),
    ]
    let filteredBatch = CloudKitVaultSyncEngine.filteringOutboxDeletes(
      staleEngineBatch,
      decisions: [
        unknownRecordID: .unknownFutureType,
        knownRecordID: .eligible,
        staleRecordID: .eligible,
      ]
    )

    let expectedBatch: [CKSyncEngine.PendingRecordZoneChange] = [
      .deleteRecord(knownRecordID),
      .deleteRecord(staleRecordID),
      .saveRecord(unknownRecordID),
    ]
    #expect(filteredBatch == expectedBatch)
    #expect(try fetchPendingMutation(recordName: unknownRecordID.recordName, in: store) != nil)
  }

  @Test
  func makeRecord_rejectsMismatchedMetadataShellIdentity() async throws {
    let (store, cardID) = try await makeStoreWithCard()
    let database = VaultSyncDatabase(store: store)
    let context = ModelContext(store.container)
    let wrongShell = CKRecord(
      recordType: VaultRecordType.activity.rawValue,
      recordID: CKRecord.ID(recordName: cardID.uuidString, zoneID: store.vaultID.zoneID())
    )
    context.insert(
      SyncMetadata(
        recordName: cardID.uuidString,
        recordType: VaultRecordType.activity.rawValue,
        systemFieldsData: VaultRecordMapper.encodeSystemFields(of: wrongShell)
      )
    )
    try context.save()

    let record = try #require(
      try await database.makeRecord(
        recordName: cardID.uuidString,
        zoneID: store.vaultID.zoneID()
      )
    )

    #expect(record.recordType == VaultRecordType.card.rawValue)
    #expect(record.recordID.recordName == cardID.uuidString)
    #expect(
      try context.fetch(FetchDescriptor<SyncMetadata>())
        .first { $0.recordName == cardID.uuidString } == nil
    )
  }

  @Test
  func enqueueActivityRetentionDeletes_removesLocalHistoryAndNoticeWithOldestFirstTombstones()
    async throws
  {
    let store = try VaultContentStore.open(vaultID: VaultID(), layout: makeTemporaryLayout())
    let context = ModelContext(store.container)
    let oldestID = UUID()
    let middleID = UUID()
    let newestID = UUID()
    let oldestDate = Date(timeIntervalSince1970: 10)
    let middleDate = Date(timeIntervalSince1970: 20)
    let newestDate = Date(timeIntervalSince1970: 30)
    for (id, createdAt) in [
      (oldestID, oldestDate),
      (middleID, middleDate),
      (newestID, newestDate),
    ] {
      context.insert(VaultActivity(id: id, createdAt: createdAt))
      context.insert(PendingSharedWithYouNotice(activityID: id))
    }
    try context.save()
    let pulseCountBefore = try context.fetchCount(FetchDescriptor<VaultNotificationPulse>())
    let database = VaultSyncDatabase(store: store)
    let generation = VaultActivityRetentionGeneration()

    let outcome = try #require(
      await database.enqueueActivityRetentionDeletes(
        [
          VaultActivityRetentionCandidate(recordName: newestID.uuidString, createdAt: newestDate),
          VaultActivityRetentionCandidate(recordName: oldestID.uuidString, createdAt: oldestDate),
          VaultActivityRetentionCandidate(recordName: middleID.uuidString, createdAt: middleDate),
        ],
        ifCurrent: generation,
        generation: generation.capture()
      )
    )

    #expect(outcome.newlyEnqueuedDeleteCount == 3)
    #expect(outcome.removedLocalActivityCount == 3)
    #expect(outcome.removedNoticeCount == 3)
    let activityDeletes = try await database.pendingChanges().filter {
      $0.recordType == .activity && $0.kind == .delete
    }
    let expectedActivityDeleteNames = [
      oldestID.uuidString,
      middleID.uuidString,
      newestID.uuidString,
    ]
    #expect(activityDeletes.map(\.recordName) == expectedActivityDeleteNames)

    let verificationContext = ModelContext(store.container)
    #expect(try verificationContext.fetchCount(FetchDescriptor<VaultActivity>()) == 0)
    #expect(try verificationContext.fetchCount(FetchDescriptor<PendingSharedWithYouNotice>()) == 0)
    // Retention only removes existing local history; it must not manufacture a
    // Pulse or delivery intent while making delete work durable.
    #expect(
      try verificationContext.fetchCount(FetchDescriptor<VaultNotificationPulse>())
        == pulseCountBefore
    )
  }

  @Test
  func enqueueActivityRetentionDeletes_isIdempotentAndUnknownItemCompletionClearsTombstone()
    async throws
  {
    let store = try VaultContentStore.open(vaultID: VaultID(), layout: makeTemporaryLayout())
    let activityID = UUID()
    let createdAt = Date(timeIntervalSince1970: 10)
    let context = ModelContext(store.container)
    context.insert(VaultActivity(id: activityID, createdAt: createdAt))
    context.insert(PendingSharedWithYouNotice(activityID: activityID))
    try context.save()
    let database = VaultSyncDatabase(store: store)
    let generation = VaultActivityRetentionGeneration()
    let candidate = VaultActivityRetentionCandidate(
      recordName: activityID.uuidString,
      createdAt: createdAt
    )

    _ = try await database.enqueueActivityRetentionDeletes(
      [candidate],
      ifCurrent: generation,
      generation: generation.capture()
    )
    let repeatedOutcome = try #require(
      await database.enqueueActivityRetentionDeletes(
        [candidate],
        ifCurrent: generation,
        generation: generation.capture()
      )
    )

    #expect(repeatedOutcome.newlyEnqueuedDeleteCount == 0)
    #expect(repeatedOutcome.removedLocalActivityCount == 0)
    #expect(repeatedOutcome.removedNoticeCount == 0)
    #expect(
      try await database.pendingChanges().filter {
        $0.recordName == activityID.uuidString && $0.kind == .delete
      }.count == 1
    )

    // `CloudKitVaultSyncEngine` routes a CKError.unknownItem delete result to
    // this same completion method, making an already-absent server Activity a
    // successful, durable cleanup outcome.
    try await database.handleCompletedDelete(recordName: activityID.uuidString)

    let verificationContext = ModelContext(store.container)
    #expect(
      try verificationContext.fetch(FetchDescriptor<PendingMutation>())
        .contains { $0.recordName == activityID.uuidString } == false
    )
    #expect(try verificationContext.fetchCount(FetchDescriptor<VaultActivity>()) == 0)
    #expect(try verificationContext.fetchCount(FetchDescriptor<PendingSharedWithYouNotice>()) == 0)
  }

  @Test
  func handleCompletedDelete_clearsTransportStateAndRetainsLogicalRows() async throws {
    let (store, cardID) = try await makeStoreWithCard()
    let (edgeID, activityID) = try await MainActor.run {
      let context = store.container.mainContext
      let edgeID = try #require(context.fetch(FetchDescriptor<CardEdge>()).first).id
      let activityID = try #require(context.fetch(FetchDescriptor<VaultActivity>()).first).id
      return (edgeID, activityID)
    }
    let database = VaultSyncDatabase(store: store)

    for recordName in [cardID.uuidString, edgeID.uuidString, activityID.uuidString] {
      let record = try #require(
        try await database.makeRecord(
          recordName: recordName,
          zoneID: store.vaultID.zoneID()
        )
      )
      try await database.handleSavedRecord(record)
    }

    try await MainActor.run {
      try store.deleteCardEdge(edgeID: edgeID)
    }
    try await database.handleCompletedDelete(recordName: edgeID.uuidString)
    try await database.handleCompletedDelete(recordName: cardID.uuidString)

    let context = ModelContext(store.container)
    let edge = try #require(
      try context.fetch(FetchDescriptor<CardEdge>()).first { $0.id == edgeID }
    )
    #expect(edge.deletedAt != nil)
    #expect(try context.fetch(FetchDescriptor<Card>()).contains { $0.id == cardID })
    #expect(try context.fetchCount(FetchDescriptor<PendingMutation>()) == 0)
    // Content tombstones are complete, while append-only Activity history and
    // its metadata remain independently synchronized.
    let metadata = try context.fetch(FetchDescriptor<SyncMetadata>())
    #expect(metadata.count == 1)
    #expect(metadata.first?.recordName == activityID.uuidString)
    #expect(metadata.first?.recordType == VaultRecordType.activity.rawValue)
  }

  @Test
  func pendingChanges_ordersEntryDeletesBeforeRetainedPayloadDeletes() async throws {
    let (store, rootEdgeID, _) = try await makeStoreWithSubtreeAndMedia()
    try await MainActor.run {
      let context = store.container.mainContext
      for pending in try context.fetch(FetchDescriptor<PendingMutation>()) {
        context.insert(
          SyncMetadata(
            recordName: pending.recordName,
            recordType: pending.recordType,
            systemFieldsData: Data()
          )
        )
        context.delete(pending)
      }
      try context.save()
      try store.deleteCardEdge(edgeID: rootEdgeID)
    }

    let database = VaultSyncDatabase(store: store)
    let recordTypes = try await database.pendingChanges().map(\.recordType)

    #expect(
      recordTypes == [
        .cardEdge,
        .cardEdge,
        .card,
        .card,
        .attachment,
        .attachmentResource,
      ]
    )
  }

  @Test
  func enqueueActivityRetentionDeletes_rejectsCandidatesFromInvalidatedAccount() async throws {
    let store = try VaultContentStore.open(vaultID: VaultID(), layout: makeTemporaryLayout())
    let database = VaultSyncDatabase(store: store)
    let generation = VaultActivityRetentionGeneration()
    let oldAccountGeneration = generation.capture()
    generation.invalidate()

    let outcome = try await database.enqueueActivityRetentionDeletes(
      [
        VaultActivityRetentionCandidate(
          recordName: UUID().uuidString,
          createdAt: Date(timeIntervalSince1970: 10)
        )
      ],
      ifCurrent: generation,
      generation: oldAccountGeneration
    )

    #expect(outcome == nil)
    #expect(try await database.pendingChanges().isEmpty)
  }

  // MARK: - Import

  @Test
  func importChanges_insertsRemoteRows() async throws {
    let store = try VaultContentStore.open(vaultID: VaultID(), layout: makeTemporaryLayout())
    let database = VaultSyncDatabase(store: store)

    let remoteCardID = UUID()
    let record = CKRecord(
      recordType: VaultRecordType.card.rawValue,
      recordID: CKRecord.ID(recordName: remoteCardID.uuidString, zoneID: store.vaultID.zoneID())
    )
    record[VaultRecordMapper.CardKey.kind] = "text"
    record[VaultRecordMapper.CardKey.body] = "from another device"
    record[VaultRecordMapper.CardKey.createdAt] = Date()
    record[VaultRecordMapper.CardKey.updatedAt] = Date()

    let outcome = try await database.importChanges(modifications: [record], deletions: [])

    #expect(outcome.importedRecordCount == 1)
    let context = ModelContext(store.container)
    let card = try context.fetch(FetchDescriptor<Card>()).first { $0.id == remoteCardID }
    #expect(card?.body == "from another device")
    // Imports never enqueue outbox rows — no upload ping-pong.
    #expect(try context.fetchCount(FetchDescriptor<PendingMutation>()) == 0)
  }

  @Test
  func importChanges_remoteActivityAndPulseCreateNoAuthoredOutboxOrNotice() async throws {
    let store = try VaultContentStore.open(vaultID: VaultID(), layout: makeTemporaryLayout())
    let database = VaultSyncDatabase(store: store)
    let remoteActivity = VaultActivity(
      kindRawValue: "futureActivityKind",
      subjectEdgeID: UUID(),
      rootEdgeID: UUID(),
      createdAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let activityRecord = CKRecord(
      recordType: VaultRecordType.activity.rawValue,
      recordID: CKRecord.ID(
        recordName: remoteActivity.recordName,
        zoneID: store.vaultID.zoneID()
      )
    )
    VaultRecordMapper.applyFields(of: remoteActivity, to: activityRecord)
    let remotePulse = VaultNotificationPulse(
      latestActivityRecordName: remoteActivity.recordName,
      kind: .unknown("futureActivityKind"),
      updatedAt: Date(timeIntervalSince1970: 1_700_000_060)
    )
    let pulseRecord = CKRecord(
      recordType: VaultRecordType.notificationPulse.rawValue,
      recordID: CKRecord.ID(
        recordName: VaultNotificationPulse.fixedRecordName,
        zoneID: store.vaultID.zoneID()
      )
    )
    VaultRecordMapper.applyFields(of: remotePulse, to: pulseRecord)

    let outcome = try await database.importChanges(
      modifications: [activityRecord, pulseRecord],
      deletions: []
    )

    let context = ModelContext(store.container)
    let importedActivity = try #require(
      try context.fetch(FetchDescriptor<VaultActivity>()).first
    )
    let importedPulse = try #require(
      try context.fetch(FetchDescriptor<VaultNotificationPulse>()).first
    )
    #expect(outcome.importedRecordCount == 2)
    #expect(importedActivity.kindRawValue == "futureActivityKind")
    #expect(importedActivity.subjectEdgeID == remoteActivity.subjectEdgeID)
    #expect(importedPulse.recordName == VaultNotificationPulse.fixedRecordName)
    #expect(importedPulse.latestActivityRecordName == remoteActivity.recordName)
    // Imports are observations, never local authored actions. They cannot
    // become upload work or Shared with You delivery intent on this device.
    #expect(try context.fetchCount(FetchDescriptor<PendingMutation>()) == 0)
    #expect(try context.fetchCount(FetchDescriptor<PendingSharedWithYouNotice>()) == 0)
  }

  @Test
  func importChanges_existingActivityKeepsItsImmutableSnapshot() async throws {
    let store = try VaultContentStore.open(vaultID: VaultID(), layout: makeTemporaryLayout())
    let database = VaultSyncDatabase(store: store)
    let activityID = UUID()
    let localActivity = VaultActivity(
      id: activityID,
      kind: .contentAdded,
      subjectEdgeID: UUID(),
      rootEdgeID: UUID(),
      createdAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let context = ModelContext(store.container)
    context.insert(localActivity)
    try context.save()

    let remoteActivity = VaultActivity(
      id: activityID,
      kindRawValue: "futureActivityKind",
      subjectEdgeID: UUID(),
      rootEdgeID: UUID(),
      createdAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
    let record = CKRecord(
      recordType: VaultRecordType.activity.rawValue,
      recordID: CKRecord.ID(recordName: activityID.uuidString, zoneID: store.vaultID.zoneID())
    )
    VaultRecordMapper.applyFields(of: remoteActivity, to: record)

    _ = try await database.importChanges(modifications: [record], deletions: [])

    let imported = try #require(
      try context.fetch(FetchDescriptor<VaultActivity>()).first { $0.id == activityID }
    )
    #expect(imported.kindRawValue == localActivity.kindRawValue)
    #expect(imported.subjectEdgeID == localActivity.subjectEdgeID)
    #expect(imported.rootEdgeID == localActivity.rootEdgeID)
    #expect(imported.createdAt == localActivity.createdAt)
  }

  @Test
  func importChanges_remoteActivityAndFixedPulseDeletionPhysicallyRemovesTransportRows()
    async throws
  {
    let store = try VaultContentStore.open(vaultID: VaultID(), layout: makeTemporaryLayout())
    let database = VaultSyncDatabase(store: store)
    let activity = VaultActivity(subjectEdgeID: UUID(), rootEdgeID: UUID())
    let activityRecord = CKRecord(
      recordType: VaultRecordType.activity.rawValue,
      recordID: CKRecord.ID(
        recordName: activity.recordName,
        zoneID: store.vaultID.zoneID()
      )
    )
    VaultRecordMapper.applyFields(of: activity, to: activityRecord)
    let pulse = VaultNotificationPulse(
      latestActivityRecordName: activity.recordName,
      kind: .contentAdded
    )
    let pulseRecord = CKRecord(
      recordType: VaultRecordType.notificationPulse.rawValue,
      recordID: CKRecord.ID(
        recordName: VaultNotificationPulse.fixedRecordName,
        zoneID: store.vaultID.zoneID()
      )
    )
    VaultRecordMapper.applyFields(of: pulse, to: pulseRecord)
    _ = try await database.importChanges(
      modifications: [activityRecord, pulseRecord],
      deletions: []
    )

    let context = ModelContext(store.container)
    context.insert(PendingSharedWithYouNotice(activityID: activity.id))
    try context.save()

    let outcome = try await database.importChanges(
      modifications: [],
      deletions: [
        RecordDeletion(
          recordName: activity.recordName,
          recordType: VaultRecordType.activity.rawValue
        ),
        RecordDeletion(
          recordName: VaultNotificationPulse.fixedRecordName,
          recordType: VaultRecordType.notificationPulse.rawValue
        ),
      ]
    )

    #expect(outcome.deletedRecordCount == 2)
    #expect(try context.fetchCount(FetchDescriptor<VaultActivity>()) == 0)
    #expect(try context.fetchCount(FetchDescriptor<VaultNotificationPulse>()) == 0)
    #expect(try context.fetchCount(FetchDescriptor<PendingSharedWithYouNotice>()) == 0)
    #expect(try context.fetchCount(FetchDescriptor<SyncMetadata>()) == 0)
  }

  @Test
  func importChanges_malformedOrUnknownTransportDeletionDoesNotEraseExistingState() async throws {
    let (store, activityID) = try await makeStoreWithParticipantActivity()
    let database = VaultSyncDatabase(store: store)
    let record = try #require(
      try await database.makeRecord(
        recordName: activityID.uuidString,
        zoneID: store.vaultID.zoneID()
      )
    )
    try await database.handleSavedRecord(record)
    let pulseRecord = try #require(
      try await database.makeRecord(
        recordName: VaultNotificationPulse.fixedRecordName,
        zoneID: store.vaultID.zoneID()
      )
    )
    try await database.handleSavedRecord(pulseRecord)

    let outcome = try await database.importChanges(
      modifications: [],
      deletions: [
        RecordDeletion(recordName: "not-a-uuid", recordType: VaultRecordType.activity.rawValue),
        RecordDeletion(recordName: activityID.uuidString, recordType: "FutureVaultRecord"),
        RecordDeletion(
          recordName: "not-the-fixed-pulse",
          recordType: VaultRecordType.notificationPulse.rawValue
        ),
      ]
    )

    let context = ModelContext(store.container)
    #expect(outcome.deletedRecordCount == 0)
    #expect(
      try context.fetch(FetchDescriptor<VaultActivity>()).contains { $0.id == activityID }
    )
    #expect(
      try context.fetch(FetchDescriptor<SyncMetadata>())
        .contains { $0.recordName == activityID.uuidString }
    )
    #expect(try context.fetchCount(FetchDescriptor<VaultNotificationPulse>()) == 1)
    #expect(
      try context.fetch(FetchDescriptor<SyncMetadata>())
        .contains { $0.recordName == VaultNotificationPulse.fixedRecordName }
    )
  }

  @Test
  func importChanges_reportsVaultInfoDisplayMetadata() async throws {
    let store = try VaultContentStore.open(vaultID: VaultID(), layout: makeTemporaryLayout())
    let database = VaultSyncDatabase(store: store)
    let icon = VaultIcon.emoji("\u{1F4DA}")
    let record = CKRecord(
      recordType: VaultRecordType.vaultInfo.rawValue,
      recordID: CKRecord.ID(recordName: store.vaultID.uuidString, zoneID: store.vaultID.zoneID())
    )
    let info = VaultInfo(vaultID: store.vaultID.rawValue, title: "Reading", icon: icon)
    VaultRecordMapper.applyFields(of: info, to: record)

    let outcome = try await database.importChanges(modifications: [record], deletions: [])

    #expect(outcome.importedVaultTitle == "Reading")
    #expect(outcome.importedVaultIcon == icon)
    let context = ModelContext(store.container)
    let importedInfo = try #require(try context.fetch(FetchDescriptor<VaultInfo>()).first)
    #expect(importedInfo.icon == icon)
    #expect(try context.fetchCount(FetchDescriptor<PendingMutation>()) == 0)
  }

  @Test
  func importChanges_localPendingSaveWins() async throws {
    let (store, cardID) = try await makeStoreWithCard()  // pending save exists
    let database = VaultSyncDatabase(store: store)

    let record = CKRecord(
      recordType: VaultRecordType.card.rawValue,
      recordID: CKRecord.ID(recordName: cardID.uuidString, zoneID: store.vaultID.zoneID())
    )
    record[VaultRecordMapper.CardKey.body] = "remote overwrite"

    let outcome = try await database.importChanges(modifications: [record], deletions: [])

    #expect(outcome.skippedConflictCount == 1)
    #expect(outcome.importedRecordCount == 0)

    let context = ModelContext(store.container)
    let card = try context.fetch(FetchDescriptor<Card>()).first { $0.id == cardID }
    #expect(card?.body == "hello")

    // But the server's change tag is on file so the local re-send is valid.
    let metadata = try context.fetch(FetchDescriptor<SyncMetadata>())
      .first { $0.recordName == cardID.uuidString }
    #expect(metadata != nil)
  }

  @Test
  func importChanges_rejectsRecordTypeCollisionBeforeOverwritingMetadata() async throws {
    let (store, cardID) = try await makeStoreWithCard()
    let database = VaultSyncDatabase(store: store)
    let cardRecord = try #require(
      try await database.makeRecord(
        recordName: cardID.uuidString,
        zoneID: store.vaultID.zoneID()
      )
    )
    try await database.handleSavedRecord(cardRecord)
    let activity = VaultActivity(id: cardID, createdAt: Date(timeIntervalSince1970: 10))
    let collidingRecord = CKRecord(
      recordType: VaultRecordType.activity.rawValue,
      recordID: CKRecord.ID(recordName: cardID.uuidString, zoneID: store.vaultID.zoneID())
    )
    VaultRecordMapper.applyFields(of: activity, to: collidingRecord)

    let outcome = try await database.importChanges(
      modifications: [collidingRecord],
      deletions: []
    )

    let context = ModelContext(store.container)
    let metadata = try #require(
      try context.fetch(FetchDescriptor<SyncMetadata>())
        .first { $0.recordName == cardID.uuidString }
    )
    #expect(outcome.importedRecordCount == 0)
    #expect(metadata.recordType == VaultRecordType.card.rawValue)
    #expect(try context.fetch(FetchDescriptor<Card>()).contains { $0.id == cardID })
    #expect(
      try context.fetch(FetchDescriptor<VaultActivity>()).contains { $0.id == cardID } == false)
  }

  @Test
  func importChanges_cardDeletionLogicallyDeletesPlacedCard() async throws {
    let (store, cardID) = try await makeStoreWithCard()
    let database = VaultSyncDatabase(store: store)
    let record = try #require(
      try await database.makeRecord(recordName: cardID.uuidString, zoneID: store.vaultID.zoneID())
    )
    try await database.handleSavedRecord(record)

    let outcome = try await database.importChanges(
      modifications: [],
      deletions: [
        RecordDeletion(recordName: cardID.uuidString, recordType: VaultRecordType.card.rawValue)
      ]
    )

    #expect(outcome.deletedRecordCount == 1)
    let context = ModelContext(store.container)
    #expect(try context.fetch(FetchDescriptor<Card>()).contains { $0.id == cardID })
    let edge = try #require(
      try context.fetch(FetchDescriptor<CardEdge>()).first { $0.cardID == cardID }
    )
    #expect(edge.deletedAt != nil)
    #expect(
      try context.fetch(FetchDescriptor<SyncMetadata>())
        .first { $0.recordName == cardID.uuidString } == nil
    )
  }

  @Test
  func importChanges_remoteRootEdgeDeletionRetainsSubtreeAndMedia() async throws {
    let (store, rootEdgeID, attachmentFileURL) = try await makeStoreWithSubtreeAndMedia()
    let database = VaultSyncDatabase(store: store)
    #expect(FileManager.default.fileExists(atPath: attachmentFileURL.path))

    let outcome = try await database.importChanges(
      modifications: [],
      deletions: [
        RecordDeletion(
          recordName: rootEdgeID.uuidString,
          recordType: VaultRecordType.cardEdge.rawValue
        )
      ]
    )

    #expect(outcome.deletedRecordCount == 1)
    let context = ModelContext(store.container)
    let edges = try context.fetch(FetchDescriptor<CardEdge>())
    #expect(edges.count == 2)
    #expect(edges.allSatisfy { $0.deletedAt != nil })
    #expect(try context.fetchCount(FetchDescriptor<Card>()) == 2)
    #expect(try context.fetchCount(FetchDescriptor<JournalVault.Attachment>()) == 1)
    #expect(try context.fetchCount(FetchDescriptor<JournalVault.AttachmentResource>()) == 1)
    // Activity history is not part of the deleted content subtree. Its upload
    // remains pending and must not be removed by relationship repair.
    let outbox = try context.fetch(FetchDescriptor<PendingMutation>())
    #expect(outbox.count == 1)
    #expect(outbox.first?.recordType == VaultRecordType.activity.rawValue)
    #expect(FileManager.default.fileExists(atPath: attachmentFileURL.path))
  }

  @Test
  func importChanges_entryDeletionRetainsPayloadWhenTombstonesArriveUnordered() async throws {
    let (store, _, attachmentFileURL) = try await makeStoreWithSubtreeAndMedia()
    let context = ModelContext(store.container)
    let edges = try context.fetch(FetchDescriptor<CardEdge>())
    let cards = try context.fetch(FetchDescriptor<Card>())
    let attachment = try #require(
      try context.fetch(FetchDescriptor<JournalVault.Attachment>()).first
    )
    let resource = try #require(
      try context.fetch(FetchDescriptor<JournalVault.AttachmentResource>()).first
    )
    let database = VaultSyncDatabase(store: store)

    var deletions = [
      RecordDeletion(
        recordName: resource.id.uuidString,
        recordType: VaultRecordType.attachmentResource.rawValue
      ),
      RecordDeletion(
        recordName: attachment.id.uuidString,
        recordType: VaultRecordType.attachment.rawValue
      ),
    ]
    deletions.append(
      contentsOf: cards.map {
        RecordDeletion(recordName: $0.id.uuidString, recordType: VaultRecordType.card.rawValue)
      }
    )
    deletions.append(
      contentsOf: edges.reversed().map {
        RecordDeletion(recordName: $0.id.uuidString, recordType: VaultRecordType.cardEdge.rawValue)
      }
    )

    let outcome = try await database.importChanges(modifications: [], deletions: deletions)

    #expect(outcome.deletedRecordCount == deletions.count)
    let verificationContext = ModelContext(store.container)
    #expect(
      try verificationContext.fetch(FetchDescriptor<CardEdge>())
        .allSatisfy { $0.deletedAt != nil }
    )
    #expect(
      Set(
        try verificationContext.fetch(FetchDescriptor<CardEdge>())
          .compactMap(\.deletedAt)
      ).count == 1
    )
    #expect(try verificationContext.fetchCount(FetchDescriptor<Card>()) == 2)
    #expect(
      try verificationContext.fetchCount(FetchDescriptor<JournalVault.Attachment>()) == 1
    )
    #expect(
      try verificationContext.fetchCount(FetchDescriptor<JournalVault.AttachmentResource>()) == 1
    )
    #expect(FileManager.default.fileExists(atPath: attachmentFileURL.path))
  }

  @Test
  func importChanges_editOnlyPrimaryResourceDeletionRemainsPhysical() async throws {
    let (store, _, attachmentFileURL) = try await makeStoreWithSubtreeAndMedia()
    let context = ModelContext(store.container)
    let resource = try #require(
      try context.fetch(FetchDescriptor<JournalVault.AttachmentResource>()).first
    )
    let database = VaultSyncDatabase(store: store)

    _ = try await database.importChanges(
      modifications: [],
      deletions: [
        RecordDeletion(
          recordName: resource.id.uuidString,
          recordType: VaultRecordType.attachmentResource.rawValue
        )
      ]
    )

    let verificationContext = ModelContext(store.container)
    #expect(
      try verificationContext.fetchCount(FetchDescriptor<JournalVault.Attachment>()) == 0
    )
    #expect(
      try verificationContext.fetchCount(FetchDescriptor<JournalVault.AttachmentResource>()) == 0
    )
    #expect(
      try verificationContext.fetch(FetchDescriptor<CardEdge>())
        .allSatisfy { $0.deletedAt == nil }
    )
    #expect(FileManager.default.fileExists(atPath: attachmentFileURL.path) == false)
  }

  @Test
  func importChanges_recreatedCardEdgeClearsLogicalDeletion() async throws {
    let (store, cardID) = try await makeStoreWithCard()
    let context = ModelContext(store.container)
    let edgeID = try #require(context.fetch(FetchDescriptor<CardEdge>()).first).id
    let database = VaultSyncDatabase(store: store)

    _ = try await database.importChanges(
      modifications: [],
      deletions: [
        RecordDeletion(
          recordName: edgeID.uuidString,
          recordType: VaultRecordType.cardEdge.rawValue
        )
      ]
    )

    let recreatedRecord = CKRecord(
      recordType: VaultRecordType.cardEdge.rawValue,
      recordID: CKRecord.ID(recordName: edgeID.uuidString, zoneID: store.vaultID.zoneID())
    )
    recreatedRecord[VaultRecordMapper.CardEdgeKey.cardID] = cardID.uuidString
    recreatedRecord[VaultRecordMapper.CardEdgeKey.sortIndex] = 0
    recreatedRecord[VaultRecordMapper.CardEdgeKey.createdAt] = Date()
    recreatedRecord[VaultRecordMapper.CardEdgeKey.updatedAt] = Date()

    _ = try await database.importChanges(modifications: [recreatedRecord], deletions: [])

    let verificationContext = ModelContext(store.container)
    let recreatedEdge = try #require(
      try verificationContext.fetch(FetchDescriptor<CardEdge>()).first { $0.id == edgeID }
    )
    #expect(recreatedEdge.deletedAt == nil)
  }

  @Test
  func importChanges_repairsImportedCardEdgeSelfCycleAsRoot() async throws {
    let store = try VaultContentStore.open(vaultID: VaultID(), layout: makeTemporaryLayout())
    let database = VaultSyncDatabase(store: store)
    let cardID = UUID()
    let edgeID = UUID()

    let cardRecord = CKRecord(
      recordType: VaultRecordType.card.rawValue,
      recordID: CKRecord.ID(recordName: cardID.uuidString, zoneID: store.vaultID.zoneID())
    )
    cardRecord[VaultRecordMapper.CardKey.kind] = "text"
    cardRecord[VaultRecordMapper.CardKey.body] = "cycle"

    let edgeRecord = CKRecord(
      recordType: VaultRecordType.cardEdge.rawValue,
      recordID: CKRecord.ID(recordName: edgeID.uuidString, zoneID: store.vaultID.zoneID())
    )
    edgeRecord[VaultRecordMapper.CardEdgeKey.cardID] = cardID.uuidString
    edgeRecord[VaultRecordMapper.CardEdgeKey.parentEdgeID] = edgeID.uuidString
    edgeRecord[VaultRecordMapper.CardEdgeKey.sortIndex] = 0

    let outcome = try await database.importChanges(
      modifications: [cardRecord, edgeRecord],
      deletions: []
    )

    #expect(outcome.repairedInvalidEdgeCount == 1)
    let context = ModelContext(store.container)
    let edge = try #require(
      try context.fetch(FetchDescriptor<CardEdge>()).first { $0.id == edgeID }
    )
    #expect(edge.parentEdgeID == nil)
    #expect(edge.cardID == cardID)
  }

  @Test
  func makeRecord_forVanishedRow_discardsPendingRow() async throws {
    let store = try VaultContentStore.open(vaultID: VaultID(), layout: makeTemporaryLayout())
    let database = VaultSyncDatabase(store: store)

    // An outbox row whose model row never existed (inconsistent state).
    let orphanID = UUID()
    let context = ModelContext(store.container)
    context.insert(
      PendingMutation(
        recordName: orphanID.uuidString,
        recordType: VaultRecordType.card.rawValue,
        kind: .save
      )
    )
    try context.save()

    let record = try await database.makeRecord(
      recordName: orphanID.uuidString,
      zoneID: store.vaultID.zoneID()
    )

    #expect(record == nil)
    #expect(try fetchPendingMutation(recordName: orphanID.uuidString, in: store) == nil)
  }
}
