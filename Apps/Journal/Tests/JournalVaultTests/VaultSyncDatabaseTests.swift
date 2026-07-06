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
      try store.container.mainContext.fetch(FetchDescriptor<JournalVault.AttachmentResource>()).first
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
  func importChanges_deletionRemovesRowMetadataAndTombstone() async throws {
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
    #expect(try context.fetch(FetchDescriptor<Card>()).first { $0.id == cardID } == nil)
    #expect(
      try context.fetch(FetchDescriptor<SyncMetadata>())
        .first { $0.recordName == cardID.uuidString } == nil
    )
  }

  @Test
  func importChanges_remoteRootEdgeDeletionCascadesSubtreeAndMedia() async throws {
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
    #expect(try context.fetchCount(FetchDescriptor<CardEdge>()) == 0)
    #expect(try context.fetchCount(FetchDescriptor<Card>()) == 0)
    #expect(try context.fetchCount(FetchDescriptor<JournalVault.Attachment>()) == 0)
    #expect(try context.fetchCount(FetchDescriptor<PendingMutation>()) == 0)
    #expect(FileManager.default.fileExists(atPath: attachmentFileURL.path) == false)
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
