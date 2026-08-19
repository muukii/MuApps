import CloudKit
import Foundation
import SwiftData
import Testing

@testable import JournalVault

/// Regression coverage for the boundary shared by user mutations and CloudKit
/// acknowledgements.
///
/// Each test deliberately keeps an old save record in the sync actor, writes
/// through a separately opened store (as the Share extension or App Intent
/// would), then acknowledges that old record. The re-armed outbox row must
/// survive: acknowledgement is confirmation of the old snapshot, not consent
/// to discard the later authored state.
@MainActor
struct VaultAuthoredMutationAcknowledgementTests {

  @Test
  func updateCardInAnotherContainerKeepsRearmedSaveAfterOldAcknowledgement() async throws {
    let layout = makeTemporaryLayout()
    let vaultID = VaultID()
    let syncStore = try VaultContentStore.open(vaultID: vaultID, layout: layout)
    let root = try #require(
      try syncStore.createThread(
        cards: [.init(kind: .text, text: "first version")],
        deliveryPolicy: .historyOnly
      ).first
    )
    let syncDatabase = VaultSyncDatabase(store: syncStore)
    let oldRecord = try #require(
      try await syncDatabase.makeRecord(
        recordName: root.cardID.uuidString,
        zoneID: vaultID.zoneID()
      )
    )

    // The writer was opened independently before the ACK, so its ModelContext
    // cannot rely on the sync store's in-memory state. This is the exact
    // app/extension interleaving the shared coordinator serializes.
    let writerStore = try VaultContentStore.open(
      vaultID: vaultID,
      layout: layout,
      recoveryPolicy: .failWithoutReset
    )
    try writerStore.updateCard(
      cardID: root.cardID,
      with: .init(kind: .text, text: "edited after send")
    )

    try await syncDatabase.handleSavedRecord(oldRecord)

    let verificationContext = ModelContext(writerStore.container)
    let card = try #require(
      try verificationContext.fetch(FetchDescriptor<Card>()).first { $0.id == root.cardID }
    )
    let pending = try #require(
      try verificationContext.fetch(FetchDescriptor<PendingMutation>()).first {
        $0.recordName == root.cardID.uuidString
      }
    )

    #expect(card.body == "edited after send")
    #expect(pending.recordType == VaultRecordType.card.rawValue)
    #expect(pending.kind == .save)
    #expect(pending.stagedAt == nil)
  }

  @Test
  func deleteCardEdgeInAnotherContainerKeepsRearmedDeleteAfterOldAcknowledgement() async throws {
    let layout = makeTemporaryLayout()
    let vaultID = VaultID()
    let syncStore = try VaultContentStore.open(vaultID: vaultID, layout: layout)
    let root = try #require(
      try syncStore.createThread(
        cards: [.init(kind: .text, text: "delete me")],
        deliveryPolicy: .historyOnly
      ).first
    )
    let syncDatabase = VaultSyncDatabase(store: syncStore)
    let oldRecord = try #require(
      try await syncDatabase.makeRecord(
        recordName: root.cardID.uuidString,
        zoneID: vaultID.zoneID()
      )
    )

    let writerStore = try VaultContentStore.open(
      vaultID: vaultID,
      layout: layout,
      recoveryPolicy: .failWithoutReset
    )
    try writerStore.deleteCardEdge(edgeID: root.id)

    try await syncDatabase.handleSavedRecord(oldRecord)

    let verificationContext = ModelContext(writerStore.container)
    let edge = try #require(
      try verificationContext.fetch(FetchDescriptor<CardEdge>()).first { $0.id == root.id }
    )
    let pending = try #require(
      try verificationContext.fetch(FetchDescriptor<PendingMutation>()).first {
        $0.recordName == root.cardID.uuidString
      }
    )

    #expect(edge.deletedAt != nil)
    #expect(pending.recordType == VaultRecordType.card.rawValue)
    #expect(pending.kind == .delete)
    #expect(pending.stagedAt == nil)
  }
}
