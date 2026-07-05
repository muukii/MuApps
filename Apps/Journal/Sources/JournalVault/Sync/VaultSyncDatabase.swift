import CloudKit
import Foundation
import SwiftData

/// A remote record deletion to apply locally.
struct RecordDeletion: Hashable, Sendable {
  let recordName: String
  let recordType: String
}

/// Background database access for one vault's sync work.
///
/// All sync-side reads and writes of a vault store go through this actor so
/// they never contend with the main context. It shares the vault's
/// `ModelContainer` (via `VaultStoreRegistry`), so imports propagate into
/// SwiftUI observation.
///
/// It owns the outbox lifecycle on the sync side: staging pending rows into
/// outgoing records, clearing them on confirmed sends, and applying the
/// conflict policy. The store-side half (enqueueing) lives in
/// `VaultContentStore`.
actor VaultSyncDatabase: ModelActor {

  nonisolated let modelExecutor: any ModelExecutor
  nonisolated let modelContainer: ModelContainer

  private let vaultID: VaultID
  private let mediaDirectoryURL: URL

  init(store: VaultContentStore) {
    self.vaultID = store.vaultID
    self.mediaDirectoryURL = store.mediaDirectoryURL
    self.modelContainer = store.container
    let context = ModelContext(store.container)
    context.autosaveEnabled = false
    self.modelExecutor = DefaultSerialModelExecutor(modelContext: context)
  }

  // MARK: - Outbox

  struct PendingChange: Hashable, Sendable {
    let recordName: String
    let recordType: String
    let kind: PendingMutation.Kind
  }

  /// Snapshot of the outbox, used to (re)seed `CKSyncEngine`'s pending-change
  /// set. `unstagingAll` clears stale in-flight markers after a relaunch so
  /// rows staged by a previous process become collectable again.
  func pendingChanges(unstagingAll: Bool = false) throws -> [PendingChange] {
    let rows = try modelContext.fetch(FetchDescriptor<PendingMutation>())
    if unstagingAll {
      for row in rows {
        row.stagedAt = nil
      }
      try modelContext.save()
    }
    return rows.map {
      PendingChange(recordName: $0.recordName, recordType: $0.recordType, kind: $0.kind)
    }
  }

  func hasPendingMutations() throws -> Bool {
    try modelContext.fetchCount(FetchDescriptor<PendingMutation>()) > 0
  }

  // MARK: - Outgoing

  /// Builds the outgoing record for one pending save and marks the row staged.
  ///
  /// Returns `nil` when there is nothing to send — the pending row is gone, it
  /// turned into a delete, or the model row vanished — and cleans up so the
  /// caller can drop the engine's pending change.
  func makeRecord(recordName: String, zoneID: CKRecordZone.ID) throws -> CKRecord? {
    guard
      let pending = try fetchPendingMutation(recordName),
      pending.kind == .save,
      let recordType = VaultRecordType(rawValue: pending.recordType)
    else {
      return nil
    }

    let record = try baseRecord(recordName: recordName, recordType: recordType, zoneID: zoneID)

    switch recordType {
    case .vaultInfo:
      guard let info = try fetchVaultInfo() else {
        try discardPendingRow(pending)
        return nil
      }
      VaultRecordMapper.applyFields(of: info, to: record)

    case .card:
      guard let id = UUID(uuidString: recordName), let card = try fetchCard(id) else {
        try discardPendingRow(pending)
        return nil
      }
      VaultRecordMapper.applyFields(of: card, to: record)

    case .cardEdge:
      guard let id = UUID(uuidString: recordName), let edge = try fetchCardEdge(id) else {
        try discardPendingRow(pending)
        return nil
      }
      VaultRecordMapper.applyFields(of: edge, to: record)

    case .attachment:
      guard let id = UUID(uuidString: recordName), let attachment = try fetchAttachment(id) else {
        try discardPendingRow(pending)
        return nil
      }
      VaultRecordMapper.applyFields(of: attachment, to: record)

    case .attachmentResource:
      guard let id = UUID(uuidString: recordName), let resource = try fetchAttachmentResource(id) else {
        try discardPendingRow(pending)
        return nil
      }
      let fileURL = mediaDirectoryURL.appending(
        path: resource.fileName,
        directoryHint: .notDirectory
      )
      let assetFileURL = FileManager.default.fileExists(atPath: fileURL.path) ? fileURL : nil
      VaultRecordMapper.applyFields(of: resource, assetFileURL: assetFileURL, to: record)
    }

    pending.stagedAt = Date()
    try modelContext.save()
    return record
  }

  /// The record shell to populate: the archived system fields when the server
  /// already knows this record (so the save carries its change tag), otherwise
  /// a brand-new record.
  private func baseRecord(
    recordName: String,
    recordType: VaultRecordType,
    zoneID: CKRecordZone.ID
  ) throws -> CKRecord {
    if let metadata = try fetchSyncMetadata(recordName),
      let shell = VaultRecordMapper.record(fromSystemFields: metadata.systemFieldsData)
    {
      return shell
    }
    return CKRecord(
      recordType: recordType.rawValue,
      recordID: CKRecord.ID(recordName: recordName, zoneID: zoneID)
    )
  }

  private func discardPendingRow(_ pending: PendingMutation) throws {
    modelContext.delete(pending)
    try modelContext.save()
  }

  // MARK: - Send results

  /// A save reached the server: adopt its system fields and clear the outbox
  /// row — unless the row was re-enqueued while the upload was in flight, in
  /// which case it stays and the newer state goes out with the next batch.
  func handleSavedRecord(_ record: CKRecord) throws {
    upsertSyncMetadata(for: record)
    if let pending = try fetchPendingMutation(record.recordID.recordName),
      pending.kind == .save,
      let stagedAt = pending.stagedAt,
      pending.enqueuedAt <= stagedAt
    {
      modelContext.delete(pending)
    }
    try modelContext.save()
  }

  /// The server rejected our save because it holds a newer record.
  ///
  /// Conflict policy (first cut): **local edits win**. Adopt the server's
  /// system fields so the next upload carries a valid change tag, keep the
  /// pending save, and let the re-send overwrite the server's user fields.
  /// Field-wise merging is an open design question
  /// (`VAULT_SYNC_DESIGN.md` 未決定事項).
  func handleServerRecordChanged(serverRecord: CKRecord) throws {
    upsertSyncMetadata(for: serverRecord)
    if let pending = try fetchPendingMutation(serverRecord.recordID.recordName) {
      pending.stagedAt = nil
    }
    try modelContext.save()
  }

  /// A staged send failed transiently; clear the in-flight marker so the row
  /// re-stages when `CKSyncEngine` retries.
  func unstage(recordName: String) throws {
    guard let pending = try fetchPendingMutation(recordName) else { return }
    pending.stagedAt = nil
    try modelContext.save()
  }

  /// A delete reached the server (or the record never existed there): the
  /// tombstone and the record's metadata are done.
  func handleCompletedDelete(recordName: String) throws {
    if let pending = try fetchPendingMutation(recordName), pending.kind == .delete {
      modelContext.delete(pending)
    }
    if let metadata = try fetchSyncMetadata(recordName) {
      modelContext.delete(metadata)
    }
    try modelContext.save()
  }

  // MARK: - Import

  struct ImportOutcome: Sendable {
    var importedRecordCount = 0
    var skippedConflictCount = 0
    var deletedRecordCount = 0
    var repairedInvalidEdgeCount = 0

    /// Attachments whose media file changed on disk (arrived or was removed);
    /// drives `VaultMediaFileChange`.
    var changedAttachmentIDs: [UUID] = []

    /// Set when a `VaultInfo` record was imported, so the catalog can pick up
    /// the vault's current title.
    var importedVaultTitle: String?
  }

  /// Imports fetched remote changes into the vault store as one transaction.
  ///
  /// Records with a pending local *save* are not applied — local wins, matching
  /// `handleServerRecordChanged` — but their metadata still updates so the next
  /// upload carries the server's change tag. Records with a pending local
  /// *delete* are skipped entirely; the tombstone will delete them remotely.
  /// Remote deletions win over local edits (open design question; documented
  /// choice for now).
  func importChanges(
    modifications: [CKRecord],
    deletions: [RecordDeletion]
  ) throws -> ImportOutcome {
    var outcome = ImportOutcome()
    var touchedEdgeTopology = false

    for record in modifications {
      let recordName = record.recordID.recordName
      upsertSyncMetadata(for: record)

      if let pending = try fetchPendingMutation(recordName) {
        switch pending.kind {
        case .save:
          outcome.skippedConflictCount += 1
        case .delete:
          break
        }
        continue
      }

      guard let recordType = VaultRecordType(rawValue: record.recordType) else { continue }

      switch recordType {
      case .vaultInfo:
        let info: VaultInfo
        if let existing = try fetchVaultInfo() {
          info = existing
        } else {
          info = VaultInfo(vaultID: vaultID.rawValue, title: "")
          modelContext.insert(info)
        }
        VaultRecordMapper.update(info, from: record)
        outcome.importedVaultTitle = info.title

      case .card:
        guard let id = UUID(uuidString: recordName) else { continue }
        let card: Card
        if let existing = try fetchCard(id) {
          card = existing
        } else {
          card = Card(id: id)
          modelContext.insert(card)
        }
        VaultRecordMapper.update(card, from: record)

      case .cardEdge:
        touchedEdgeTopology = true
        guard let id = UUID(uuidString: recordName) else { continue }
        let edge: CardEdge
        if let existing = try fetchCardEdge(id) {
          edge = existing
        } else {
          edge = CardEdge(id: id, cardID: id)
          modelContext.insert(edge)
        }
        VaultRecordMapper.update(edge, from: record)

      case .attachment:
        guard let id = UUID(uuidString: recordName) else { continue }
        let attachment: Attachment
        if let existing = try fetchAttachment(id) {
          attachment = existing
        } else {
          guard let primaryResourceID = Self.attachmentPrimaryResourceID(from: record) else {
            continue
          }
          attachment = Attachment(id: id, cardID: id, primaryResourceID: primaryResourceID)
          modelContext.insert(attachment)
        }
        VaultRecordMapper.update(attachment, from: record)

      case .attachmentResource:
        guard let id = UUID(uuidString: recordName) else { continue }
        let resource: AttachmentResource
        if let existing = try fetchAttachmentResource(id) {
          resource = existing
        } else {
          resource = AttachmentResource(id: id, attachmentID: id, role: .unknown)
          modelContext.insert(resource)
        }
        VaultRecordMapper.update(resource, from: record)

        if let asset = record[VaultRecordMapper.AttachmentResourceKey.file] as? CKAsset,
          let sourceURL = asset.fileURL
        {
          do {
            try importAssetFile(from: sourceURL, to: resource)
            outcome.changedAttachmentIDs.append(resource.attachmentID)
          } catch {
            // The row stays; the file can be repaired by a later fetch.
          }
        }
      }

      outcome.importedRecordCount += 1
    }

    for deletion in deletions {
      if deletion.recordType == VaultRecordType.cardEdge.rawValue {
        touchedEdgeTopology = true
      }
      try applyRemoteDeletion(deletion, outcome: &outcome)
    }

    if touchedEdgeTopology {
      outcome.repairedInvalidEdgeCount = try repairInvalidCardEdgeCycles()
    }

    try modelContext.save()
    return outcome
  }

  private func applyRemoteDeletion(
    _ deletion: RecordDeletion,
    outcome: inout ImportOutcome
  ) throws {
    let recordName = deletion.recordName

    if let recordType = VaultRecordType(rawValue: deletion.recordType),
      let id = UUID(uuidString: recordName)
    {
      switch recordType {
      case .vaultInfo:
        if let info = try fetchVaultInfo() {
          modelContext.delete(info)
        }
      case .card:
        try deleteImportedCard(cardID: id, outcome: &outcome)
      case .cardEdge:
        try deleteImportedEdgeSubtree(edgeID: id, outcome: &outcome)
      case .attachment:
        try deleteImportedAttachment(attachmentID: id, outcome: &outcome)
      case .attachmentResource:
        try deleteImportedAttachmentResource(resourceID: id, outcome: &outcome)
      }
    }

    try removeSyncState(recordName: recordName)
    outcome.deletedRecordCount += 1
  }

  private func deleteImportedEdgeSubtree(
    edgeID: UUID,
    outcome: inout ImportOutcome
  ) throws {
    let allEdges = try modelContext.fetch(FetchDescriptor<CardEdge>())
    guard let root = allEdges.first(where: { $0.id == edgeID }) else { return }

    let subtree = edgeSubtree(root: root, allEdges: allEdges)
    let cardIDs = Set(subtree.map(\.cardID))
    let attachments = try modelContext.fetch(FetchDescriptor<Attachment>())
      .filter { cardIDs.contains($0.cardID) }
    let cards = try modelContext.fetch(FetchDescriptor<Card>())
      .filter { cardIDs.contains($0.id) }

    for attachment in attachments {
      try deleteImportedAttachment(attachment, outcome: &outcome)
    }
    for card in cards {
      modelContext.delete(card)
      try removeSyncState(recordName: card.id.uuidString)
    }
    for edge in subtree {
      modelContext.delete(edge)
      try removeSyncState(recordName: edge.id.uuidString)
    }
  }

  private func edgeSubtree(root: CardEdge, allEdges: [CardEdge]) -> [CardEdge] {
    var childrenByParent: [UUID: [CardEdge]] = [:]
    for edge in allEdges {
      if let parentEdgeID = edge.parentEdgeID {
        childrenByParent[parentEdgeID, default: []].append(edge)
      }
    }

    var subtree: [CardEdge] = []
    var visited = Set<UUID>()
    var stack = [root]
    while let edge = stack.popLast() {
      guard visited.insert(edge.id).inserted else { continue }
      subtree.append(edge)
      stack.append(contentsOf: childrenByParent[edge.id] ?? [])
    }
    return subtree
  }

  private func deleteImportedCard(
    cardID: UUID,
    outcome: inout ImportOutcome
  ) throws {
    let allEdges = try modelContext.fetch(FetchDescriptor<CardEdge>())
    let edges = allEdges.filter { $0.cardID == cardID }
    if edges.isEmpty == false {
      for edge in edges {
        try deleteImportedEdgeSubtree(edgeID: edge.id, outcome: &outcome)
      }
      return
    }

    let attachments = try modelContext.fetch(FetchDescriptor<Attachment>())
      .filter { $0.cardID == cardID }
    for attachment in attachments {
      try deleteImportedAttachment(attachment, outcome: &outcome)
    }
    if let card = try fetchCard(cardID) {
      modelContext.delete(card)
    }
    try removeSyncState(recordName: cardID.uuidString)
  }

  private func deleteImportedAttachment(
    attachmentID: UUID,
    outcome: inout ImportOutcome
  ) throws {
    if let attachment = try fetchAttachment(attachmentID) {
      try deleteImportedAttachment(attachment, outcome: &outcome)
    }
    try removeSyncState(recordName: attachmentID.uuidString)
  }

  private func deleteImportedAttachment(
    _ attachment: Attachment,
    outcome: inout ImportOutcome
  ) throws {
    let attachmentID = attachment.id
    let resources = try fetchAttachmentResources(attachmentID: attachmentID)
    for resource in resources {
      try deleteImportedAttachmentResourceFileAndRow(resource, outcome: &outcome)
    }
    modelContext.delete(attachment)
    try removeSyncState(recordName: attachmentID.uuidString)
  }

  private func deleteImportedAttachmentResource(
    resourceID: UUID,
    outcome: inout ImportOutcome
  ) throws {
    if let resource = try fetchAttachmentResource(resourceID) {
      try deleteImportedAttachmentResource(resource, outcome: &outcome)
    }
    try removeSyncState(recordName: resourceID.uuidString)
  }

  private func deleteImportedAttachmentResource(
    _ resource: AttachmentResource,
    outcome: inout ImportOutcome
  ) throws {
    let attachmentID = resource.attachmentID
    if let attachment = try fetchAttachment(attachmentID),
      attachment.primaryResourceID == resource.id
    {
      try deleteImportedAttachment(attachment, outcome: &outcome)
      return
    }
    try deleteImportedAttachmentResourceFileAndRow(resource, outcome: &outcome)
  }

  private func deleteImportedAttachmentResourceFileAndRow(
    _ resource: AttachmentResource,
    outcome: inout ImportOutcome
  ) throws {
    let attachmentID = resource.attachmentID
    let fileURL = mediaDirectoryURL.appending(
      path: resource.fileName,
      directoryHint: .notDirectory
    )
    if FileManager.default.fileExists(atPath: fileURL.path) {
      try? FileManager.default.removeItem(at: fileURL)
      outcome.changedAttachmentIDs.append(attachmentID)
    }
    modelContext.delete(resource)
    try removeSyncState(recordName: resource.id.uuidString)
  }

  private func removeSyncState(recordName: String) throws {
    if let pending = try fetchPendingMutation(recordName) {
      modelContext.delete(pending)
    }
    if let metadata = try fetchSyncMetadata(recordName) {
      modelContext.delete(metadata)
    }
  }

  /// Keeps imported topology safe to render. Missing parents are allowed
  /// because CloudKit may deliver parent and child records in different fetches,
  /// but an already-materialized cycle must not enter the recursive UI tree.
  private func repairInvalidCardEdgeCycles() throws -> Int {
    let edges = try modelContext.fetch(FetchDescriptor<CardEdge>())
    let edgesByID = Dictionary(uniqueKeysWithValues: edges.map { ($0.id, $0) })
    var repairedCount = 0

    for edge in edges where edge.parentEdgeID != nil {
      if parentChainContainsCycle(startingAt: edge, edgesByID: edgesByID) {
        edge.parentEdgeID = nil
        repairedCount += 1
      }
    }

    return repairedCount
  }

  private func parentChainContainsCycle(
    startingAt edge: CardEdge,
    edgesByID: [UUID: CardEdge]
  ) -> Bool {
    var visited = Set([edge.id])
    var nextParentID = edge.parentEdgeID

    while let parentID = nextParentID {
      guard visited.insert(parentID).inserted else {
        return true
      }
      guard let parent = edgesByID[parentID] else {
        return false
      }
      nextParentID = parent.parentEdgeID
    }

    return false
  }

  private func importAssetFile(from sourceURL: URL, to resource: AttachmentResource) throws {
    let destination = mediaDirectoryURL.appending(
      path: resource.fileName,
      directoryHint: .notDirectory
    )
    if FileManager.default.fileExists(atPath: destination.path) {
      try FileManager.default.removeItem(at: destination)
    }
    try FileManager.default.copyItem(at: sourceURL, to: destination)
  }

  private func upsertSyncMetadata(for record: CKRecord) {
    let data = VaultRecordMapper.encodeSystemFields(of: record)
    if let existing = try? fetchSyncMetadata(record.recordID.recordName) {
      existing.systemFieldsData = data
      existing.lastSyncedAt = Date()
    } else {
      modelContext.insert(
        SyncMetadata(
          recordName: record.recordID.recordName,
          recordType: record.recordType,
          systemFieldsData: data
        )
      )
    }
  }

  // MARK: - Fetch helpers

  private func fetchPendingMutation(_ recordName: String) throws -> PendingMutation? {
    var descriptor = FetchDescriptor<PendingMutation>(
      predicate: #Predicate { $0.recordName == recordName }
    )
    descriptor.fetchLimit = 1
    return try modelContext.fetch(descriptor).first
  }

  private func fetchSyncMetadata(_ recordName: String) throws -> SyncMetadata? {
    var descriptor = FetchDescriptor<SyncMetadata>(
      predicate: #Predicate { $0.recordName == recordName }
    )
    descriptor.fetchLimit = 1
    return try modelContext.fetch(descriptor).first
  }

  private func fetchVaultInfo() throws -> VaultInfo? {
    var descriptor = FetchDescriptor<VaultInfo>()
    descriptor.fetchLimit = 1
    return try modelContext.fetch(descriptor).first
  }

  private func fetchCard(_ id: UUID) throws -> Card? {
    var descriptor = FetchDescriptor<Card>(predicate: #Predicate { $0.id == id })
    descriptor.fetchLimit = 1
    return try modelContext.fetch(descriptor).first
  }

  private func fetchCardEdge(_ id: UUID) throws -> CardEdge? {
    var descriptor = FetchDescriptor<CardEdge>(predicate: #Predicate { $0.id == id })
    descriptor.fetchLimit = 1
    return try modelContext.fetch(descriptor).first
  }

  private func fetchAttachment(_ id: UUID) throws -> Attachment? {
    var descriptor = FetchDescriptor<Attachment>(predicate: #Predicate { $0.id == id })
    descriptor.fetchLimit = 1
    return try modelContext.fetch(descriptor).first
  }

  private func fetchAttachmentResource(_ id: UUID) throws -> AttachmentResource? {
    var descriptor = FetchDescriptor<AttachmentResource>(predicate: #Predicate { $0.id == id })
    descriptor.fetchLimit = 1
    return try modelContext.fetch(descriptor).first
  }

  private func fetchAttachmentResources(attachmentID: UUID) throws -> [AttachmentResource] {
    let descriptor = FetchDescriptor<AttachmentResource>(
      predicate: #Predicate { $0.attachmentID == attachmentID }
    )
    return try modelContext.fetch(descriptor)
  }

  private static func attachmentPrimaryResourceID(from record: CKRecord) -> UUID? {
    (record[VaultRecordMapper.AttachmentKey.primaryResourceID] as? String)
      .flatMap(UUID.init(uuidString:))
  }
}
