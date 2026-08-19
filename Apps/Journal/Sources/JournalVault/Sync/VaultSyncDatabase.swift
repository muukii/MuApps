import CloudKit
import Foundation
import SwiftData

/// A remote record deletion to apply locally.
struct RecordDeletion: Hashable, Sendable {
  let recordName: String
  let recordType: String
}

/// Prevents a malformed retention query result from overwriting unrelated
/// durable transport work that happens to share a record name.
enum ActivityRetentionEnqueueError: Error, Equatable, Sendable {
  case conflictingPendingMutation(recordName: String, recordType: String)
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
  private let authoredWriteCoordinator: VaultAuthoredWriteCoordinator

  init(store: VaultContentStore) {
    self.vaultID = store.vaultID
    self.mediaDirectoryURL = store.mediaDirectoryURL
    self.authoredWriteCoordinator = store.authoredWriteCoordinator
    self.modelContainer = store.container
    let context = ModelContext(store.container)
    context.autosaveEnabled = false
    self.modelExecutor = DefaultSerialModelExecutor(modelContext: context)
  }

  // MARK: - Outbox

  struct PendingChange: Hashable, Sendable {
    let recordName: String
    let recordType: VaultRecordType
    let kind: PendingMutation.Kind
  }

  /// Durable effects of one CloudKit saved-record acknowledgement.
  ///
  /// The sync engine consumes these independent facts only after this database
  /// transaction commits: an Activity acknowledgement can schedule retention,
  /// while a matching local-only Shared with You intent can wake the app's
  /// delivery worker. Import, duplicate acknowledgement, and a re-armed
  /// outbox row leave both values `false`.
  struct SavedRecordOutcome: Hashable, Sendable {
    let didAcknowledgeLocalActivity: Bool
    let didMakeSharedWithYouNoticeReady: Bool

    static let none = Self(
      didAcknowledgeLocalActivity: false,
      didMakeSharedWithYouNoticeReady: false
    )
  }

  /// Result of atomically turning server-selected Activity history into local
  /// cleanup plus durable CloudKit delete work.
  struct ActivityRetentionEnqueueOutcome: Hashable, Sendable {
    let deleteRecordNames: [String]
    let newlyEnqueuedDeleteCount: Int
    let removedLocalActivityCount: Int
    let removedNoticeCount: Int

    var hasDeleteWork: Bool { deleteRecordNames.isEmpty == false }
  }

  /// Snapshot of the outbox, used to (re)seed `CKSyncEngine`'s pending-change
  /// set. `unstagingAll` clears stale in-flight markers after a relaunch so
  /// rows staged by a previous process become collectable again.
  func pendingChanges(unstagingAll: Bool = false) throws -> [PendingChange] {
    try withFreshCrossProcessState {
      try pendingChangesInCurrentContext(unstagingAll: unstagingAll)
    }
  }

  private func pendingChangesInCurrentContext(
    unstagingAll: Bool
  ) throws -> [PendingChange] {
    let rows = try modelContext.fetch(FetchDescriptor<PendingMutation>())
    if unstagingAll {
      for row in rows {
        row.stagedAt = nil
      }
      try modelContext.save()
    }
    return rows.sorted(by: Self.pendingChangePrecedes).compactMap { row in
      // A persisted raw value from an unknown future build stays in the
      // durable outbox rather than being deleted. This build cannot safely
      // manufacture its record, so it must not feed the engine a change that
      // would be dropped by `makeRecord`.
      guard let recordType = VaultRecordType(rawValue: row.recordType) else { return nil }
      return PendingChange(recordName: row.recordName, recordType: recordType, kind: row.kind)
    }
  }

  /// Whether a persisted future record-type tombstone must stay out of a stale
  /// `CKSyncEngine` state after an app downgrade. The raw outbox row remains
  /// durable for the future build that understands its record type.
  func hasUnknownDeletePendingMutation(recordName: String) throws -> Bool {
    try withFreshCrossProcessState {
      guard
        let pending = try fetchPendingMutation(recordName),
        pending.kind == .delete
      else {
        return false
      }
      return VaultRecordType(rawValue: pending.recordType) == nil
    }
  }

  /// Orders semantic entry tombstones ahead of their retained payload rows.
  /// Receiving devices apply the same order, which establishes logical entry
  /// deletion before attachment and resource cleanup decisions are made.
  private static func pendingChangePrecedes(
    _ lhs: PendingMutation,
    _ rhs: PendingMutation
  ) -> Bool {
    let lhsPriority = pendingChangePriority(lhs)
    let rhsPriority = pendingChangePriority(rhs)
    if lhsPriority != rhsPriority {
      return lhsPriority < rhsPriority
    }
    if lhs.enqueuedAt != rhs.enqueuedAt {
      return lhs.enqueuedAt < rhs.enqueuedAt
    }
    return lhs.recordName < rhs.recordName
  }

  private static func pendingChangePriority(_ mutation: PendingMutation) -> Int {
    let recordType = VaultRecordType(rawValue: mutation.recordType)
    switch mutation.kind {
    case .delete:
      switch recordType {
      case .cardEdge: return 0
      case .card: return 1
      case .attachment: return 2
      case .attachmentResource: return 3
      case .vaultInfo, .activity: return 4
      case .notificationPulse: return 5
      case .none: return 6
      }
    case .save:
      switch recordType {
      case .vaultInfo: return 10
      case .card: return 11
      case .cardEdge: return 12
      case .attachment: return 13
      case .attachmentResource: return 14
      // Activity is durable history, while Pulse is only a coalescible
      // attention signal. Present the latter after every content and Activity
      // save, though CloudKit still does not guarantee remote commit order.
      case .activity: return 15
      case .notificationPulse: return 16
      case .none: return 17
      }
    }
  }

  func hasPendingMutations() throws -> Bool {
    try pendingChanges().isEmpty == false
  }

  /// Deletes local Activity history and its matching local-only notice while
  /// durably enqueuing the corresponding remote tombstones in one transaction.
  ///
  /// Candidates come from the complete, server-authoritative retention query
  /// in oldest-first order. Repeating the call is safe: an already pending
  /// Activity delete remains staged as-is, while any lingering local row or
  /// notice is still removed before the transaction commits.
  func enqueueActivityRetentionDeletes(
    _ candidates: [VaultActivityRetentionCandidate],
    ifCurrent accountGeneration: VaultActivityRetentionGeneration,
    generation: UInt64
  ) throws -> ActivityRetentionEnqueueOutcome? {
    try withFreshCrossProcessState {
      try accountGeneration.withCurrentGeneration(generation) {
        try enqueueActivityRetentionDeletesInCurrentAccount(candidates)
      }
    }
  }

  /// Performs the local transaction after the caller's account generation was
  /// synchronously validated. Keeping this body non-async ensures the
  /// generation lock spans the final check through `modelContext.save()`.
  private func enqueueActivityRetentionDeletesInCurrentAccount(
    _ candidates: [VaultActivityRetentionCandidate]
  ) throws -> ActivityRetentionEnqueueOutcome {
    var uniqueCandidates: [VaultActivityRetentionCandidate] = []
    var seenRecordNames = Set<String>()
    for candidate in candidates where seenRecordNames.insert(candidate.recordName).inserted {
      uniqueCandidates.append(candidate)
    }

    // A single UUID name is the transport identity across record types. Do not
    // let a malformed server Activity replace unrelated durable content work.
    // Preflight every row before mutating the model context so a conflict has
    // no partial local cleanup side effect.
    for candidate in uniqueCandidates {
      if let pending = try fetchPendingMutation(candidate.recordName),
        pending.recordType != VaultRecordType.activity.rawValue
      {
        throw ActivityRetentionEnqueueError.conflictingPendingMutation(
          recordName: candidate.recordName,
          recordType: pending.recordType
        )
      }
    }

    var newlyEnqueuedDeleteCount = 0
    var removedLocalActivityCount = 0
    var removedNoticeCount = 0

    do {
      for candidate in uniqueCandidates {
        if let pending = try fetchPendingMutation(candidate.recordName) {
          if pending.kind != .delete {
            pending.kind = .delete
            // The server's createdAt preserves oldest-first retention order
            // when CKSyncEngine asks the outbox for its next batch.
            pending.enqueuedAt = candidate.createdAt
            pending.stagedAt = nil
            newlyEnqueuedDeleteCount += 1
          }
        } else {
          modelContext.insert(
            PendingMutation(
              recordName: candidate.recordName,
              recordType: VaultRecordType.activity.rawValue,
              kind: .delete,
              enqueuedAt: candidate.createdAt
            )
          )
          newlyEnqueuedDeleteCount += 1
        }

        guard let activityID = UUID(uuidString: candidate.recordName) else { continue }
        if let activity = try fetchActivity(activityID) {
          modelContext.delete(activity)
          removedLocalActivityCount += 1
        }
        if try removePendingSharedWithYouNotice(activityID: activityID) {
          removedNoticeCount += 1
        }
      }
      try modelContext.save()
    } catch {
      modelContext.rollback()
      throw error
    }

    return ActivityRetentionEnqueueOutcome(
      deleteRecordNames: uniqueCandidates.map(\.recordName),
      newlyEnqueuedDeleteCount: newlyEnqueuedDeleteCount,
      removedLocalActivityCount: removedLocalActivityCount,
      removedNoticeCount: removedNoticeCount
    )
  }

  // MARK: - Outgoing

  /// Builds the outgoing record for one pending save and marks the row staged.
  ///
  /// Returns `nil` when there is nothing to send — the pending row is gone, it
  /// turned into a delete, or the model row vanished — and cleans up so the
  /// caller can drop the engine's pending change.
  func makeRecord(recordName: String, zoneID: CKRecordZone.ID) throws -> CKRecord? {
    try withFreshCrossProcessState {
      try makeRecordInCurrentContext(recordName: recordName, zoneID: zoneID)
    }
  }

  private func makeRecordInCurrentContext(
    recordName: String,
    zoneID: CKRecordZone.ID
  ) throws -> CKRecord? {
    guard
      let pending = try fetchPendingMutation(recordName),
      pending.kind == .save
    else {
      return nil
    }
    // `pendingChanges()` never schedules an unrecognized type, but an older
    // CKSyncEngine state can still ask for one after an app downgrade. Keep
    // that durable row intact rather than deleting data this build cannot map.
    guard let recordType = VaultRecordType(rawValue: pending.recordType) else { return nil }

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
      guard let id = UUID(uuidString: recordName), let resource = try fetchAttachmentResource(id)
      else {
        try discardPendingRow(pending)
        return nil
      }
      let fileURL = mediaDirectoryURL.appending(
        path: resource.fileName,
        directoryHint: .notDirectory
      )
      let assetFileURL = FileManager.default.fileExists(atPath: fileURL.path) ? fileURL : nil
      VaultRecordMapper.applyFields(of: resource, assetFileURL: assetFileURL, to: record)

    case .activity:
      guard let id = UUID(uuidString: recordName), let activity = try fetchActivity(id) else {
        try discardPendingRow(pending)
        return nil
      }
      VaultRecordMapper.applyFields(of: activity, to: record)

    case .notificationPulse:
      guard
        recordName == VaultNotificationPulse.fixedRecordName,
        let pulse = try fetchNotificationPulse()
      else {
        try discardPendingRow(pending)
        return nil
      }
      VaultRecordMapper.applyFields(of: pulse, to: record)
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
    if let metadata = try fetchSyncMetadata(recordName) {
      if metadata.recordType == recordType.rawValue,
        let shell = VaultRecordMapper.record(fromSystemFields: metadata.systemFieldsData),
        shell.recordType == recordType.rawValue,
        shell.recordID.recordName == recordName,
        shell.recordID.zoneID == zoneID
      {
        return shell
      }

      // System fields describe server identity and change tags. Never reuse a
      // stale or malformed shell for a different record type, name, or zone.
      // The live row can still be uploaded as a fresh record; a later server
      // acknowledgement will replace this invalid bookkeeping safely.
      modelContext.delete(metadata)
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
  ///
  /// Returns the committed outcomes for a locally staged Activity save and its
  /// matching Shared with You intent. The sync engine uses the first outcome to
  /// schedule retention and the second to broadcast a ready-notice event.
  /// Remote imports, duplicate acknowledgements, and re-armed rows never
  /// report either outcome.
  @discardableResult
  func handleSavedRecord(_ record: CKRecord) throws -> SavedRecordOutcome {
    try withFreshCrossProcessState {
      try handleSavedRecordInCurrentContext(record)
    }
  }

  private func handleSavedRecordInCurrentContext(
    _ record: CKRecord
  ) throws -> SavedRecordOutcome {
    guard let recordType = VaultRecordType(rawValue: record.recordType) else { return .none }
    guard
      try recordIdentityIsCompatible(
        recordName: record.recordID.recordName,
        recordType: recordType
      )
    else {
      return .none
    }
    upsertSyncMetadata(for: record)
    var didAcknowledgeLocalActivity = false
    if let pending = try fetchPendingMutation(record.recordID.recordName),
      pending.recordType == recordType.rawValue,
      pending.kind == .save,
      let stagedAt = pending.stagedAt,
      pending.enqueuedAt <= stagedAt
    {
      modelContext.delete(pending)
      didAcknowledgeLocalActivity = recordType == .activity
    }

    let didMakeSharedWithYouNoticeReady: Bool
    switch recordType {
    case .activity where didAcknowledgeLocalActivity:
      didMakeSharedWithYouNoticeReady = try markSharedWithYouNoticeReadyIfMatchingActivity(record)
    case .vaultInfo, .card, .cardEdge, .attachment, .attachmentResource, .notificationPulse:
      didMakeSharedWithYouNoticeReady = false
    case .activity:
      didMakeSharedWithYouNoticeReady = false
    }
    try modelContext.save()
    return SavedRecordOutcome(
      didAcknowledgeLocalActivity: didAcknowledgeLocalActivity,
      didMakeSharedWithYouNoticeReady: didMakeSharedWithYouNoticeReady
    )
  }

  /// The server rejected our save because it holds a newer record.
  ///
  /// Conflict policy (first cut): **local edits win**. Adopt the server's
  /// system fields so the next upload carries a valid change tag, keep the
  /// pending save, and let the re-send overwrite the server's user fields.
  /// Field-wise merging is an open design question
  /// (`VAULT_SYNC_DESIGN.md` 未決定事項).
  func handleServerRecordChanged(serverRecord: CKRecord) throws {
    try withFreshCrossProcessState {
      try handleServerRecordChangedInCurrentContext(serverRecord: serverRecord)
    }
  }

  private func handleServerRecordChangedInCurrentContext(serverRecord: CKRecord) throws {
    guard let recordType = VaultRecordType(rawValue: serverRecord.recordType) else { return }
    guard
      try recordIdentityIsCompatible(
        recordName: serverRecord.recordID.recordName,
        recordType: recordType
      )
    else {
      return
    }
    upsertSyncMetadata(for: serverRecord)
    if let pending = try fetchPendingMutation(serverRecord.recordID.recordName) {
      pending.stagedAt = nil
    }
    try modelContext.save()
  }

  /// A staged send failed transiently; clear the in-flight marker so the row
  /// re-stages when `CKSyncEngine` retries.
  func unstage(recordName: String) throws {
    try withFreshCrossProcessState {
      guard let pending = try fetchPendingMutation(recordName) else { return }
      pending.stagedAt = nil
      try modelContext.save()
    }
  }

  /// A delete reached the server (or the record never existed there): the
  /// tombstone and the record's metadata are done.
  func handleCompletedDelete(recordName: String) throws {
    try withFreshCrossProcessState {
      try handleCompletedDeleteInCurrentContext(recordName: recordName)
    }
  }

  private func handleCompletedDeleteInCurrentContext(recordName: String) throws {
    let pending = try fetchPendingMutation(recordName)
    let metadata = try fetchSyncMetadata(recordName)
    let recordType =
      pending.flatMap { VaultRecordType(rawValue: $0.recordType) }
      ?? metadata.flatMap { VaultRecordType(rawValue: $0.recordType) }

    if let pending, pending.kind == .delete {
      modelContext.delete(pending)
    }
    if let metadata {
      modelContext.delete(metadata)
    }

    if recordType == .activity,
      let activityID = UUID(uuidString: recordName)
    {
      try removePendingSharedWithYouNotice(activityID: activityID)
    }
    try modelContext.save()
  }

  // MARK: - Import

  struct ImportOutcome: Sendable {
    var importedRecordCount = 0
    var skippedConflictCount = 0
    var deletedRecordCount = 0
    var repairedInvalidEdgeCount = 0

    /// Set when a `VaultInfo` record was imported, so the catalog can pick up
    /// the vault's current title and any synchronized icon.
    var importedVaultTitle: String?
    var importedVaultIcon: VaultIcon?
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
    try withFreshCrossProcessState {
      try importChangesInCurrentContext(
        modifications: modifications,
        deletions: deletions
      )
    }
  }

  /// Applies one fetched batch while holding the same vault lock as authored
  /// app/extension writes, so conflict checks and fixed-Pulse materialization
  /// observe a single fresh durable state.
  private func importChangesInCurrentContext(
    modifications: [CKRecord],
    deletions: [RecordDeletion]
  ) throws -> ImportOutcome {
    var outcome = ImportOutcome()
    var touchedEdgeTopology = false
    var touchedRelationships = false
    let logicalDeletionDate = Date()

    for record in modifications {
      let recordName = record.recordID.recordName
      guard let recordType = VaultRecordType(rawValue: record.recordType) else { continue }

      // Activity and Pulse have stronger record-name and payload contracts than
      // ordinary UUID-backed content. Reject malformed remote shapes before
      // storing transport metadata, so they cannot later become a valid shell
      // for an unrelated local row.
      switch recordType {
      case .activity:
        guard
          UUID(uuidString: recordName) != nil,
          VaultRecordMapper.canMaterializeActivity(from: record)
        else {
          continue
        }
      case .notificationPulse:
        guard
          recordName == VaultNotificationPulse.fixedRecordName,
          VaultRecordMapper.canMaterializeNotificationPulse(from: record)
        else {
          continue
        }
      case .vaultInfo, .card, .cardEdge, .attachment, .attachmentResource:
        break
      }

      // CloudKit record name is the transport identity across every record
      // type. Reject a mismatched remote shape before touching SyncMetadata or
      // materializing a second local type under the same identity.
      guard
        try recordIdentityIsCompatible(
          recordName: recordName,
          recordType: recordType
        )
      else {
        continue
      }
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
        outcome.importedVaultIcon = info.icon

      case .card:
        touchedRelationships = true
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
        touchedRelationships = true
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
        touchedRelationships = true
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
        touchedRelationships = true
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
          } catch {
            // The row stays; the file can be repaired by a later fetch.
          }
        }

      case .activity:
        guard
          let id = UUID(uuidString: recordName),
          let activity = VaultRecordMapper.activity(id: id, from: record)
        else {
          continue
        }
        // Activity is immutable domain history. An existing snapshot already
        // represents the logical action and must not be rewritten by later
        // fetches; only its SyncMetadata was refreshed above.
        if try fetchActivity(id) == nil {
          modelContext.insert(activity)
        }

      case .notificationPulse:
        let pulse: VaultNotificationPulse
        if let existing = try fetchNotificationPulse() {
          pulse = existing
        } else {
          pulse = VaultNotificationPulse(
            latestActivityRecordName: "",
            kind: .contentAdded,
            updatedAt: .distantPast
          )
          modelContext.insert(pulse)
        }
        VaultRecordMapper.update(pulse, from: record)
      }

      outcome.importedRecordCount += 1
    }

    for deletion in deletions.sorted(by: Self.remoteDeletionPrecedes) {
      if let recordType = VaultRecordType(rawValue: deletion.recordType) {
        switch recordType {
        case .cardEdge:
          touchedEdgeTopology = true
          touchedRelationships = true
        case .card, .attachment, .attachmentResource:
          touchedRelationships = true
        case .vaultInfo, .activity, .notificationPulse:
          break
        }
      }
      try applyRemoteDeletion(
        deletion,
        logicalDeletionDate: logicalDeletionDate,
        outcome: &outcome
      )
    }

    if touchedRelationships {
      try repairRelationships()
    }

    if touchedEdgeTopology {
      outcome.repairedInvalidEdgeCount = try repairInvalidCardEdgeCycles()
    }

    try modelContext.save()
    return outcome
  }

  private func applyRemoteDeletion(
    _ deletion: RecordDeletion,
    logicalDeletionDate: Date,
    outcome: inout ImportOutcome
  ) throws {
    let recordName = deletion.recordName

    // A deletion with an unknown type must not erase transport state solely by
    // record name. A future app version may use that name for a row this build
    // cannot identify safely.
    guard let recordType = VaultRecordType(rawValue: deletion.recordType) else { return }
    guard
      try recordIdentityIsCompatible(
        recordName: recordName,
        recordType: recordType
      )
    else {
      return
    }

    switch recordType {
    case .vaultInfo:
      guard UUID(uuidString: recordName) != nil else { return }
      if let info = try fetchVaultInfo() {
        modelContext.delete(info)
      }

    case .card:
      guard let id = UUID(uuidString: recordName) else { return }
      try deleteImportedCard(cardID: id, deletedAt: logicalDeletionDate)

    case .cardEdge:
      guard let id = UUID(uuidString: recordName) else { return }
      try deleteImportedEdgeSubtree(edgeID: id, deletedAt: logicalDeletionDate)

    case .attachment:
      guard let id = UUID(uuidString: recordName) else { return }
      try deleteImportedAttachment(attachmentID: id)

    case .attachmentResource:
      guard let id = UUID(uuidString: recordName) else { return }
      try deleteImportedAttachmentResource(resourceID: id)

    case .activity:
      guard let id = UUID(uuidString: recordName) else { return }
      if let activity = try fetchActivity(id) {
        modelContext.delete(activity)
      }
      // A remote deletion wins over a local authored Activity as well. Remove
      // any undelivered local-only intent so a later worker cannot post a
      // notice for history that no longer exists in the vault.
      try removePendingSharedWithYouNotice(activityID: id)

    case .notificationPulse:
      guard recordName == VaultNotificationPulse.fixedRecordName else { return }
      if let pulse = try fetchNotificationPulse() {
        modelContext.delete(pulse)
      }
    }

    try removeSyncState(recordName: recordName)
    outcome.deletedRecordCount += 1
  }

  private static func remoteDeletionPrecedes(
    _ lhs: RecordDeletion,
    _ rhs: RecordDeletion
  ) -> Bool {
    let lhsPriority = remoteDeletionPriority(lhs)
    let rhsPriority = remoteDeletionPriority(rhs)
    if lhsPriority != rhsPriority {
      return lhsPriority < rhsPriority
    }
    return lhs.recordName < rhs.recordName
  }

  private static func remoteDeletionPriority(_ deletion: RecordDeletion) -> Int {
    switch VaultRecordType(rawValue: deletion.recordType) {
    case .cardEdge: return 0
    case .card: return 1
    case .attachment: return 2
    case .attachmentResource: return 3
    case .vaultInfo, .activity: return 4
    case .notificationPulse: return 5
    case .none: return 6
    }
  }

  /// Applies an entry-level CloudKit deletion without detaching local models.
  ///
  /// The complete subtree remains available for a future local restore. Sync
  /// metadata and outbox rows are transport state and can be discarded once
  /// the remote records are known to be gone.
  private func deleteImportedEdgeSubtree(edgeID: UUID, deletedAt: Date) throws {
    let allEdges = try modelContext.fetch(FetchDescriptor<CardEdge>())
    guard let root = allEdges.first(where: { $0.id == edgeID }) else { return }

    let subtree = edgeSubtree(root: root, allEdges: allEdges)
    let cardIDs = Set(subtree.map(\.cardID))
    let attachments = try modelContext.fetch(FetchDescriptor<Attachment>())
      .filter { cardIDs.contains($0.cardID) }
    let attachmentIDs = Set(attachments.map(\.id))
    let resources = try modelContext.fetch(FetchDescriptor<AttachmentResource>())
      .filter { attachmentIDs.contains($0.attachmentID) }
    let cards = try modelContext.fetch(FetchDescriptor<Card>())
      .filter { cardIDs.contains($0.id) }

    for resource in resources {
      try removeSyncState(recordName: resource.id.uuidString)
    }
    for attachment in attachments {
      try removeSyncState(recordName: attachment.id.uuidString)
    }
    for card in cards {
      try removeSyncState(recordName: card.id.uuidString)
    }
    for edge in subtree {
      if edge.deletedAt == nil {
        edge.deletedAt = deletedAt
      }
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

  private func deleteImportedCard(cardID: UUID, deletedAt: Date) throws {
    let allEdges = try modelContext.fetch(FetchDescriptor<CardEdge>())
    let edges = allEdges.filter { $0.cardID == cardID }
    if edges.isEmpty == false {
      for edge in edges {
        try deleteImportedEdgeSubtree(edgeID: edge.id, deletedAt: deletedAt)
      }
      return
    }

    let attachments = try modelContext.fetch(FetchDescriptor<Attachment>())
      .filter { $0.cardID == cardID }
    for attachment in attachments {
      try deleteImportedAttachment(attachment)
    }
    if let card = try fetchCard(cardID) {
      modelContext.delete(card)
    }
    try removeSyncState(recordName: cardID.uuidString)
  }

  private func deleteImportedAttachment(attachmentID: UUID) throws {
    if let attachment = try fetchAttachment(attachmentID) {
      try deleteImportedAttachment(attachment)
    }
    try removeSyncState(recordName: attachmentID.uuidString)
  }

  private func deleteImportedAttachment(_ attachment: Attachment) throws {
    if try isCardLogicallyDeleted(attachment.cardID) {
      let resources = try fetchAttachmentResources(attachmentID: attachment.id)
      for resource in resources {
        try removeSyncState(recordName: resource.id.uuidString)
      }
      try removeSyncState(recordName: attachment.id.uuidString)
      return
    }

    let attachmentID = attachment.id
    let resources = try fetchAttachmentResources(attachmentID: attachmentID)
    for resource in resources {
      try deleteImportedAttachmentResourceFileAndRow(resource)
    }
    modelContext.delete(attachment)
    try removeSyncState(recordName: attachmentID.uuidString)
  }

  private func deleteImportedAttachmentResource(resourceID: UUID) throws {
    if let resource = try fetchAttachmentResource(resourceID) {
      try deleteImportedAttachmentResource(resource)
    }
    try removeSyncState(recordName: resourceID.uuidString)
  }

  private func deleteImportedAttachmentResource(_ resource: AttachmentResource) throws {
    let attachmentID = resource.attachmentID
    if let attachment = try fetchAttachment(attachmentID) {
      if try isCardLogicallyDeleted(attachment.cardID) {
        try removeSyncState(recordName: resource.id.uuidString)
        return
      }
      if attachment.primaryResourceID == resource.id {
        try deleteImportedAttachment(attachment)
        return
      }
    }
    try deleteImportedAttachmentResourceFileAndRow(resource)
  }

  private func isCardLogicallyDeleted(_ cardID: UUID) throws -> Bool {
    let edges = try modelContext.fetch(FetchDescriptor<CardEdge>())
    return edges.contains { edge in
      edge.cardID == cardID && edge.deletedAt != nil
    }
  }

  private func deleteImportedAttachmentResourceFileAndRow(
    _ resource: AttachmentResource
  ) throws {
    let fileURL = mediaDirectoryURL.appending(
      path: resource.fileName,
      directoryHint: .notDirectory
    )
    if FileManager.default.fileExists(atPath: fileURL.path) {
      try? FileManager.default.removeItem(at: fileURL)
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

  /// Resolves transport reference ids into SwiftData relationships after an
  /// import batch. Missing targets are allowed: another CloudKit fetch can
  /// deliver the referenced row later and this repair pass will connect it then.
  private func repairRelationships() throws {
    let cards = try modelContext.fetch(FetchDescriptor<Card>())
    let edges = try modelContext.fetch(FetchDescriptor<CardEdge>())
    let attachments = try modelContext.fetch(FetchDescriptor<Attachment>())
    let resources = try modelContext.fetch(FetchDescriptor<AttachmentResource>())

    let cardsByID = Dictionary(uniqueKeysWithValues: cards.map { ($0.id, $0) })
    let edgesByID = Dictionary(uniqueKeysWithValues: edges.map { ($0.id, $0) })
    let attachmentsByID = Dictionary(uniqueKeysWithValues: attachments.map { ($0.id, $0) })

    for edge in edges {
      let resolvedCard = cardsByID[edge.cardReferenceID]
      if edge.card?.id != resolvedCard?.id {
        edge.card = resolvedCard
      }

      let resolvedParent: CardEdge?
      if let parentEdgeReferenceID = edge.parentEdgeReferenceID,
        parentEdgeReferenceID != edge.id
      {
        resolvedParent = edgesByID[parentEdgeReferenceID]
      } else {
        resolvedParent = nil
      }
      if edge.parent?.id != resolvedParent?.id {
        edge.parent = resolvedParent
      }
    }

    for attachment in attachments {
      let resolvedCard = cardsByID[attachment.cardReferenceID]
      if attachment.card?.id != resolvedCard?.id {
        attachment.card = resolvedCard
      }
    }

    for resource in resources {
      let resolvedAttachment = attachmentsByID[resource.attachmentReferenceID]
      if resource.attachment?.id != resolvedAttachment?.id {
        resource.attachment = resolvedAttachment
      }
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
        edge.setParentEdgeReferenceID(nil)
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
    resource.noteLocalFileChange()
  }

  private func upsertSyncMetadata(for record: CKRecord) {
    let data = VaultRecordMapper.encodeSystemFields(of: record)
    if let existing = try? fetchSyncMetadata(record.recordID.recordName) {
      existing.recordType = record.recordType
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

  /// Verifies that one CloudKit record name denotes exactly one local type.
  ///
  /// Metadata and outbox rows participate alongside materialized domain rows:
  /// accepting a different type in any of those stores would overwrite the
  /// archived CloudKit identity and could later upload or delete the wrong
  /// model under that record name.
  private func recordIdentityIsCompatible(
    recordName: String,
    recordType: VaultRecordType
  ) throws -> Bool {
    if recordType == .vaultInfo, recordName != vaultID.uuidString {
      return false
    }
    if recordType == .notificationPulse,
      recordName != VaultNotificationPulse.fixedRecordName
    {
      return false
    }
    if let metadata = try fetchSyncMetadata(recordName),
      metadata.recordType != recordType.rawValue
    {
      return false
    }
    if let pending = try fetchPendingMutation(recordName),
      pending.recordType != recordType.rawValue
    {
      return false
    }

    var materializedTypes = Set<VaultRecordType>()
    if recordName == VaultNotificationPulse.fixedRecordName,
      try fetchNotificationPulse() != nil
    {
      materializedTypes.insert(.notificationPulse)
    }
    guard let identifier = UUID(uuidString: recordName) else {
      return materializedTypes.allSatisfy { $0 == recordType }
    }

    if let info = try fetchVaultInfo(), info.vaultID == identifier {
      materializedTypes.insert(.vaultInfo)
    }
    if try fetchCard(identifier) != nil {
      materializedTypes.insert(.card)
    }
    if try fetchCardEdge(identifier) != nil {
      materializedTypes.insert(.cardEdge)
    }
    if try fetchAttachment(identifier) != nil {
      materializedTypes.insert(.attachment)
    }
    if try fetchAttachmentResource(identifier) != nil {
      materializedTypes.insert(.attachmentResource)
    }
    if try fetchActivity(identifier) != nil {
      materializedTypes.insert(.activity)
    }
    return materializedTypes.allSatisfy { $0 == recordType }
  }

  /// Advances only the origin device's matching notice after its immutable
  /// Activity has actually been acknowledged by CloudKit. Import never calls
  /// this method, and terminal/future states remain untouched.
  private func markSharedWithYouNoticeReadyIfMatchingActivity(_ record: CKRecord) throws -> Bool {
    guard
      let activityID = UUID(uuidString: record.recordID.recordName),
      let activity = try fetchActivity(activityID),
      activity.id == activityID,
      let notice = try fetchPendingSharedWithYouNotice(activityID: activityID)
    else {
      return false
    }

    switch notice.state {
    case .waitingForActivityUpload:
      notice.stateRawValue = PendingSharedWithYouNotice.State.ready.rawValue
      return true
    case .ready, .attempted, .skipped, .unknown:
      return false
    }
  }

  /// Synchronizes sync-side outbox work with app/extension authored writes.
  ///
  /// `VaultSyncDatabase` keeps a long-lived ModelContext, while another
  /// Tinycurve process can commit through its own container. Rollback drops
  /// registered snapshots before the locked fetch so ACK decisions observe the
  /// latest durable re-arm instead of deleting a row from stale context state.
  private func withFreshCrossProcessState<Result>(
    _ operation: () throws -> Result
  ) throws -> Result {
    try authoredWriteCoordinator.withExclusiveAccess {
      modelContext.rollback()
      modelContext.processPendingChanges()
      return try operation()
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

  private func fetchActivity(_ id: UUID) throws -> VaultActivity? {
    var descriptor = FetchDescriptor<VaultActivity>(predicate: #Predicate { $0.id == id })
    descriptor.fetchLimit = 1
    return try modelContext.fetch(descriptor).first
  }

  /// Fetches only the singleton whose fixed local and CloudKit identity is
  /// valid. A malformed duplicate is never treated as the transport Pulse.
  private func fetchNotificationPulse() throws -> VaultNotificationPulse? {
    try modelContext.fetch(FetchDescriptor<VaultNotificationPulse>()).first {
      $0.recordName == VaultNotificationPulse.fixedRecordName
    }
  }

  private func fetchPendingSharedWithYouNotice(
    activityID: UUID
  ) throws -> PendingSharedWithYouNotice? {
    var descriptor = FetchDescriptor<PendingSharedWithYouNotice>(
      predicate: #Predicate { $0.activityID == activityID }
    )
    descriptor.fetchLimit = 1
    return try modelContext.fetch(descriptor).first
  }

  /// Removes the local-only delivery intent associated with a history record.
  ///
  /// Returning whether a row existed lets retention confirm it changed the
  /// notice and Activity in the same SwiftData transaction without ever
  /// creating a replacement notice.
  @discardableResult
  private func removePendingSharedWithYouNotice(activityID: UUID) throws -> Bool {
    if let notice = try fetchPendingSharedWithYouNotice(activityID: activityID) {
      modelContext.delete(notice)
      return true
    }
    return false
  }

  private func fetchAttachmentResources(attachmentID: UUID) throws -> [AttachmentResource] {
    let descriptor = FetchDescriptor<AttachmentResource>(
      predicate: #Predicate { $0.attachmentReferenceID == attachmentID }
    )
    return try modelContext.fetch(descriptor)
  }

  private static func attachmentPrimaryResourceID(from record: CKRecord) -> UUID? {
    (record[VaultRecordMapper.AttachmentKey.primaryResourceID] as? String)
      .flatMap(UUID.init(uuidString:))
  }
}
