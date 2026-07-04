import CloudKit
import Foundation
import OSLog
import SwiftData

/// The CloudKit-backed `VaultSyncEngine`: an app-lifetime actor that owns the
/// transport between vault content stores and CloudKit.
///
/// One `CKSyncEngine` per database — private (owned vaults) and shared
/// (participant vaults) — with one custom record zone per vault. Zone names
/// embed the vault ID, so fetched changes route to the right store by parsing
/// the zone name; unknown vault zones are materialized into the catalog (a
/// vault created on the user's other device, or a joined share).
///
/// `CKSyncEngine` owns scheduling, retries, change tokens, and push
/// subscriptions (durable, idempotent infrastructure — never created per
/// screen); this actor owns the mapping between engine events and vault
/// stores. Zones are created lazily: the first record save into a missing zone
/// fails with `zoneNotFound`, which queues the zone save and retries.
///
/// Ownership note: `CKSyncEngine` retains its delegate (this actor) and this
/// actor retains both engines — an intentional cycle for an app-lifetime
/// service, same as the legacy `MediaSyncEngine`.
public actor CloudKitVaultSyncEngine: VaultSyncEngine, CKSyncEngineDelegate {

  private let container: CKContainer
  private let layout: VaultStoreLayout
  private let catalog: VaultCatalogStore
  private let registry: VaultStoreRegistry
  private let log = Logger(subsystem: "app.muukii.journal", category: "VaultSync")

  private var engines: [CKDatabase.Scope: CKSyncEngine] = [:]
  private var syncDatabases: [VaultID: VaultSyncDatabase] = [:]
  private var descriptors: [VaultID: VaultDescriptor] = [:]
  private var localMutationTask: Task<Void, Never>?

  public init(
    containerIdentifier: String = "iCloud.app.muukii.journal",
    layout: VaultStoreLayout,
    catalog: VaultCatalogStore,
    registry: VaultStoreRegistry
  ) {
    self.container = CKContainer(identifier: containerIdentifier)
    self.layout = layout
    self.catalog = catalog
    self.registry = registry
  }

  // MARK: - VaultSyncEngine

  public func start() async {
    guard localMutationTask == nil else { return }

    do {
      try layout.ensureRootDirectories()
    } catch {
      log.error("cannot create vault directories, sync disabled: \(error)")
      return
    }

    engines[.private] = makeEngine(scope: .private)
    engines[.shared] = makeEngine(scope: .shared)

    await refreshDescriptors()

    // Reseed the engines' pending sets from each vault's durable outbox. This
    // recovers work enqueued right before a crash and survives engine state
    // resets; re-adding an already pending change is a no-op.
    for descriptor in descriptors.values {
      await seedPendingChanges(for: descriptor, unstagingAll: true)
    }

    localMutationTask = Task {
      for await vaultID in registry.localMutations() {
        await handleLocalMutation(vaultID: vaultID)
      }
    }
  }

  public func resolveInitialVaultAvailability() async -> VaultInitialAvailabilityResolution {
    await start()

    guard engines[.private] != nil, engines[.shared] != nil else {
      return .unresolved("CloudKit sync engine could not start.")
    }

    do {
      switch try await container.accountStatus() {
      case .available:
        try await fetchInitialVaultAvailability()
        await refreshDescriptors()
        return .resolvedWithCloudKit

      case .noAccount:
        return .resolvedWithoutICloud("No iCloud account is signed in.")

      case .restricted:
        return .resolvedWithoutICloud("iCloud access is restricted for this account or device.")

      case .couldNotDetermine:
        return .resolvedWithDeferredCloudKit("Could not determine iCloud account status.")

      case .temporarilyUnavailable:
        return .resolvedWithDeferredCloudKit("iCloud account status is temporarily unavailable.")

      @unknown default:
        return .resolvedWithDeferredCloudKit("Unknown iCloud account status.")
      }
    } catch {
      return .resolvedWithDeferredCloudKit(error.localizedDescription)
    }
  }

  public func activate(_ vaultID: VaultID) async {
    await refreshDescriptorsIfUnknown(vaultID)
    guard
      let descriptor = descriptors[vaultID],
      let engine = engines[databaseScope(for: descriptor)]
    else {
      log.error("activate for unknown vault \(vaultID.uuidString, privacy: .public)")
      return
    }

    do {
      try await engine.fetchChanges(.init(scope: .zoneIDs([descriptor.zoneID])))
    } catch {
      log.error("activate fetch failed \(vaultID.uuidString, privacy: .public): \(error)")
    }

    do {
      let database = try syncDatabase(for: descriptor)
      if try await database.hasPendingMutations() {
        try await engine.sendChanges()
      }
    } catch {
      log.error("activate send failed \(vaultID.uuidString, privacy: .public): \(error)")
    }
  }

  public func prepareShare(for vaultID: VaultID) async throws -> VaultSharePreparation {
    await ensureDescriptorsLoaded()
    await refreshDescriptorsIfUnknown(vaultID)

    guard let descriptor = descriptors[vaultID] else {
      throw VaultSharePreparationError.vaultNotFound(vaultID)
    }
    guard descriptor.ownership == .owned else {
      throw VaultSharePreparationError.participantVault(vaultID)
    }

    let database = container.privateCloudDatabase
    try await saveZoneIfNeeded(descriptor.zoneID, database: database)
    await seedPendingChanges(for: descriptor, unstagingAll: false)

    let share: CKShare
    if let existingShare = try await fetchZoneWideShare(zoneID: descriptor.zoneID, database: database) {
      share = existingShare
    } else {
      let newShare = CKShare(recordZoneID: descriptor.zoneID)
      newShare[CKShare.SystemFieldKey.title] = descriptor.title
      newShare.publicPermission = .none
      share = try await saveShare(newShare, database: database)
    }

    try await catalog.applyShareInfo(
      vaultID: descriptor.vaultID,
      isShared: true,
      shareURL: share.url,
      shareRecordName: share.recordID.recordName,
      participantCount: max(1, share.participants.count),
      permission: .owner
    )

    return VaultSharePreparation(share: share, container: container)
  }

  public func acceptShare(metadata: CKShare.Metadata) async throws -> VaultShareAcceptance {
    if engines[.shared] == nil {
      await start()
    }

    let acceptedShare = try await acceptSingleShare(metadata: metadata)
    let acceptedZoneID = acceptedShare.recordID.zoneID
    let acceptedVaultID = VaultID(zoneName: acceptedZoneID.zoneName)

    try await fetchAcceptedSharedVaultChanges(acceptedZoneID: acceptedZoneID)
    await refreshDescriptors()

    return VaultShareAcceptance(share: acceptedShare, vaultID: acceptedVaultID)
  }

  // MARK: - CKSyncEngineDelegate

  public func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
    let scope = syncEngine.database.databaseScope

    switch event {
    case .stateUpdate(let update):
      saveEngineState(update.stateSerialization, scope: scope)

    case .accountChange(let change):
      // Vault data outlives account changes locally for now; the sign-out
      // policy (wipe vs keep) is an open product decision.
      log.notice("account change: \(String(describing: change.changeType), privacy: .public)")

    case .fetchedDatabaseChanges(let changes):
      await handleFetchedDatabaseChanges(changes, scope: scope)

    case .fetchedRecordZoneChanges(let changes):
      await handleFetchedRecordZoneChanges(changes, scope: scope)

    case .sentRecordZoneChanges(let sent):
      await handleSentRecordZoneChanges(sent, engine: syncEngine)

    case .sentDatabaseChanges:
      break

    case .willFetchChanges, .willFetchRecordZoneChanges, .didFetchRecordZoneChanges,
      .didFetchChanges, .willSendChanges, .didSendChanges:
      break

    @unknown default:
      log.debug("unhandled sync event \(String(describing: event), privacy: .public)")
    }
  }

  public func nextRecordZoneChangeBatch(
    _ context: CKSyncEngine.SendChangesContext,
    syncEngine: CKSyncEngine
  ) async -> CKSyncEngine.RecordZoneChangeBatch? {
    let scope = context.options.scope
    let pending = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
    guard pending.isEmpty == false else { return nil }

    return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { recordID in
      await self.record(for: recordID, engine: syncEngine)
    }
  }

  // MARK: - Outgoing

  /// Builds the record for one pending save, or drops the pending change when
  /// the row no longer exists (deleted before its upload ran).
  private func record(for recordID: CKRecord.ID, engine: CKSyncEngine) async -> CKRecord? {
    do {
      guard let database = try syncDatabase(forZone: recordID.zoneID) else {
        engine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
        return nil
      }
      guard
        let record = try await database.makeRecord(
          recordName: recordID.recordName,
          zoneID: recordID.zoneID
        )
      else {
        engine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
        return nil
      }
      return record
    } catch {
      log.error("build record failed \(recordID.recordName, privacy: .public): \(error)")
      return nil
    }
  }

  private func handleSentRecordZoneChanges(
    _ sent: CKSyncEngine.Event.SentRecordZoneChanges,
    engine: CKSyncEngine
  ) async {
    for record in sent.savedRecords {
      do {
        try await syncDatabase(forZone: record.recordID.zoneID)?.handleSavedRecord(record)
      } catch {
        log.error("confirm save failed \(record.recordID.recordName, privacy: .public): \(error)")
      }
    }

    for failure in sent.failedRecordSaves {
      let recordID = failure.record.recordID
      let database = try? syncDatabase(forZone: recordID.zoneID)

      switch failure.error.code {
      case .serverRecordChanged:
        // Conflict. Policy lives in VaultSyncDatabase.handleServerRecordChanged
        // (local wins); re-queue so the merged save goes out again.
        if let serverRecord = failure.error.serverRecord {
          try? await database?.handleServerRecordChanged(serverRecord: serverRecord)
          engine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
        }

      case .zoneNotFound, .userDeletedZone:
        // First save into a fresh vault (zones are created lazily) or the zone
        // vanished — (re)create it and retry the record.
        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: recordID.zoneID))])
        engine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
        try? await database?.unstage(recordName: recordID.recordName)

      default:
        // Transient failures (network, throttling) are retried by CKSyncEngine
        // itself; unstage so the row re-stages into the retry batch.
        try? await database?.unstage(recordName: recordID.recordName)
        log.error("record save failed \(recordID.recordName, privacy: .public): \(failure.error)")
      }
    }

    for recordID in sent.deletedRecordIDs {
      try? await syncDatabase(forZone: recordID.zoneID)?
        .handleCompletedDelete(recordName: recordID.recordName)
    }

    for (recordID, error) in sent.failedRecordDeletes {
      switch error.code {
      case .unknownItem, .zoneNotFound, .userDeletedZone:
        // Nothing to delete remotely — the tombstone has served its purpose.
        try? await syncDatabase(forZone: recordID.zoneID)?
          .handleCompletedDelete(recordName: recordID.recordName)
      default:
        log.error("record delete failed \(recordID.recordName, privacy: .public): \(error)")
      }
    }
  }

  // MARK: - Incoming

  private func handleFetchedDatabaseChanges(
    _ changes: CKSyncEngine.Event.FetchedDatabaseChanges,
    scope: CKDatabase.Scope
  ) async {
    for modification in changes.modifications {
      let zoneID = modification.zoneID
      guard let vaultID = VaultID(zoneName: zoneID.zoneName) else { continue }
      await materializeVaultIfNeeded(vaultID: vaultID, zoneID: zoneID, scope: scope)
    }

    for deletion in changes.deletions {
      guard let vaultID = VaultID(zoneName: deletion.zoneID.zoneName) else { continue }
      // Zone-level deletion: the owner deleted the vault, the share was
      // revoked, or iCloud data was reset. The recovery/repair flow is not
      // designed yet — keep local data untouched and surface the fact.
      log.error(
        """
        vault zone removed remotely \
        (\(String(describing: deletion.reason), privacy: .public)): \
        \(vaultID.uuidString, privacy: .public)
        """
      )
    }
  }

  private func handleFetchedRecordZoneChanges(
    _ changes: CKSyncEngine.Event.FetchedRecordZoneChanges,
    scope: CKDatabase.Scope
  ) async {
    var modificationsByZone: [CKRecordZone.ID: [CKRecord]] = [:]
    for modification in changes.modifications {
      modificationsByZone[modification.record.recordID.zoneID, default: []]
        .append(modification.record)
    }

    var deletionsByZone: [CKRecordZone.ID: [RecordDeletion]] = [:]
    for deletion in changes.deletions {
      deletionsByZone[deletion.recordID.zoneID, default: []].append(
        RecordDeletion(recordName: deletion.recordID.recordName, recordType: deletion.recordType)
      )
    }

    let zoneIDs = Set(modificationsByZone.keys).union(deletionsByZone.keys)
    for zoneID in zoneIDs {
      guard let vaultID = VaultID(zoneName: zoneID.zoneName) else { continue }
      await materializeVaultIfNeeded(vaultID: vaultID, zoneID: zoneID, scope: scope)
      guard let descriptor = descriptors[vaultID] else { continue }

      do {
        let database = try syncDatabase(for: descriptor)
        let outcome = try await database.importChanges(
          modifications: modificationsByZone[zoneID] ?? [],
          deletions: deletionsByZone[zoneID] ?? []
        )

        if let title = outcome.importedVaultTitle {
          try? await catalog.applyImportedVaultInfo(vaultID: vaultID, title: title)
        }
        try? await catalog.noteVaultSynced(vaultID)

        if outcome.changedAttachmentIDs.isEmpty == false {
          VaultMediaFileChange.post(vaultID: vaultID, attachmentIDs: outcome.changedAttachmentIDs)
        }

        log.info(
          """
          vault \(vaultID.uuidString, privacy: .public): imported \
          \(outcome.importedRecordCount) modified / \(outcome.deletedRecordCount) deleted, \
          \(outcome.skippedConflictCount) held for local edits
          """
        )
      } catch {
        log.error("import failed for vault \(vaultID.uuidString, privacy: .public): \(error)")
      }
    }
  }

  /// A zone appeared that this device has no catalog row for — a vault created
  /// on the user's other device (private database) or a newly joined share
  /// (shared database). Materialize the local side so fetched records have a
  /// home; the title arrives with the vault's `VaultInfo` record.
  private func materializeVaultIfNeeded(
    vaultID: VaultID,
    zoneID: CKRecordZone.ID,
    scope: CKDatabase.Scope
  ) async {
    guard descriptors[vaultID] == nil else { return }
    await refreshDescriptors()
    guard descriptors[vaultID] == nil else { return }

    let descriptor = VaultDescriptor(
      vaultID: vaultID,
      title: "",
      ownership: scope == .shared ? .participant : .owned,
      zoneOwnerName: scope == .shared ? zoneID.ownerName : nil
    )
    do {
      try await catalog.materializeRemoteVault(descriptor)
      descriptors[vaultID] = descriptor
      log.info("materialized remote vault \(vaultID.uuidString, privacy: .public)")
    } catch {
      log.error("materialize vault failed \(vaultID.uuidString, privacy: .public): \(error)")
    }
  }

  // MARK: - Local mutations

  private func handleLocalMutation(vaultID: VaultID) async {
    await refreshDescriptorsIfUnknown(vaultID)
    guard let descriptor = descriptors[vaultID] else {
      log.error("local mutation for unknown vault \(vaultID.uuidString, privacy: .public)")
      return
    }
    await seedPendingChanges(for: descriptor, unstagingAll: false)
  }

  /// Turns the vault's `PendingMutation` rows into engine pending changes.
  private func seedPendingChanges(for descriptor: VaultDescriptor, unstagingAll: Bool) async {
    guard let engine = engines[databaseScope(for: descriptor)] else { return }
    do {
      let database = try syncDatabase(for: descriptor)
      let changes = try await database.pendingChanges(unstagingAll: unstagingAll)
      guard changes.isEmpty == false else { return }

      let zoneID = descriptor.zoneID
      engine.state.add(
        pendingRecordZoneChanges: changes.map { change in
          let recordID = CKRecord.ID(recordName: change.recordName, zoneID: zoneID)
          switch change.kind {
          case .save:
            return .saveRecord(recordID)
          case .delete:
            return .deleteRecord(recordID)
          }
        }
      )
      await sendSeededPendingChanges(engine: engine, vaultID: descriptor.vaultID)
    } catch {
      log.error(
        "seed pending changes failed \(descriptor.vaultID.uuidString, privacy: .public): \(error)"
      )
    }
  }

  /// Wakes CloudKit immediately after durable outbox rows become engine pending
  /// changes, so foreground writes do not rely on CKSyncEngine's implicit
  /// scheduling window.
  private func sendSeededPendingChanges(engine: CKSyncEngine, vaultID: VaultID) async {
    do {
      try await engine.sendChanges()
    } catch {
      log.error("send seeded changes failed \(vaultID.uuidString, privacy: .public): \(error)")
    }
  }

  // MARK: - Routing

  private func databaseScope(for descriptor: VaultDescriptor) -> CKDatabase.Scope {
    switch descriptor.ownership {
    case .owned:
      return .private
    case .participant:
      return .shared
    }
  }

  private func syncDatabase(for descriptor: VaultDescriptor) throws -> VaultSyncDatabase {
    if let existing = syncDatabases[descriptor.vaultID] {
      return existing
    }
    let database = VaultSyncDatabase(store: try registry.store(for: descriptor.vaultID))
    syncDatabases[descriptor.vaultID] = database
    return database
  }

  private func syncDatabase(forZone zoneID: CKRecordZone.ID) throws -> VaultSyncDatabase? {
    guard
      let vaultID = VaultID(zoneName: zoneID.zoneName),
      let descriptor = descriptors[vaultID]
    else {
      return nil
    }
    return try syncDatabase(for: descriptor)
  }

  private func refreshDescriptors() async {
    do {
      let all = try await catalog.vaultDescriptors()
      descriptors = Dictionary(uniqueKeysWithValues: all.map { ($0.vaultID, $0) })
    } catch {
      log.error("read catalog failed: \(error)")
    }
  }

  private func ensureDescriptorsLoaded() async {
    guard descriptors.isEmpty else { return }
    await refreshDescriptors()
  }

  private func refreshDescriptorsIfUnknown(_ vaultID: VaultID) async {
    guard descriptors[vaultID] == nil else { return }
    await refreshDescriptors()
  }

  // MARK: - Zone-wide sharing

  private func fetchZoneWideShare(
    zoneID: CKRecordZone.ID,
    database: CKDatabase
  ) async throws -> CKShare? {
    let recordID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)
    do {
      let record = try await database.record(for: recordID)
      guard let share = record as? CKShare else {
        throw VaultSharePreparationError.shareRecordTypeMismatch
      }
      return share
    } catch let error as CKError where error.isUnknownItem(for: recordID) {
      return nil
    }
  }

  private func saveZoneIfNeeded(
    _ zoneID: CKRecordZone.ID,
    database: CKDatabase
  ) async throws {
    _ = try await database.save(CKRecordZone(zoneID: zoneID))
  }

  private func saveShare(_ share: CKShare, database: CKDatabase) async throws -> CKShare {
    guard let savedShare = try await database.save(share) as? CKShare else {
      throw VaultSharePreparationError.shareRecordTypeMismatch
    }
    return savedShare
  }

  // MARK: - Share acceptance

  private func acceptSingleShare(metadata: CKShare.Metadata) async throws -> CKShare {
    do {
      let results = try await container.accept([metadata])
      guard let result = results[metadata] else {
        throw VaultShareAcceptanceError.missingAcceptedShareResult
      }

      switch result {
      case .success(let share):
        return share
      case .failure(let error):
        throw VaultShareAcceptanceError.acceptFailed(error.localizedDescription)
      }
    } catch let error as VaultShareAcceptanceError {
      throw error
    } catch {
      throw VaultShareAcceptanceError.acceptFailed(error.localizedDescription)
    }
  }

  /// Fetches broadly enough for `CKSyncEngine` to learn about the newly accepted
  /// shared zone, then lets the existing event handlers materialize and import
  /// that vault.
  private func fetchAcceptedSharedVaultChanges(acceptedZoneID: CKRecordZone.ID) async throws {
    guard let sharedEngine = engines[.shared] else {
      throw VaultShareAcceptanceError.sharedSyncEngineUnavailable
    }

    var options = CKSyncEngine.FetchChangesOptions(scope: .all)
    options.prioritizedZoneIDs = [acceptedZoneID]
    try await sharedEngine.fetchChanges(options)
  }

  private func fetchInitialVaultAvailability() async throws {
    if let privateEngine = engines[.private] {
      try await privateEngine.fetchChanges(.init(scope: .all))
    }

    if let sharedEngine = engines[.shared] {
      try await sharedEngine.fetchChanges(.init(scope: .all))
    }
  }

  // MARK: - Engine construction & state persistence

  private func makeEngine(scope: CKDatabase.Scope) -> CKSyncEngine {
    let database = scope == .shared ? container.sharedCloudDatabase : container.privateCloudDatabase
    return CKSyncEngine(
      .init(
        database: database,
        stateSerialization: loadEngineState(scope: scope),
        delegate: self
      )
    )
  }

  private func engineStateFileURL(scope: CKDatabase.Scope) -> URL {
    let fileName = scope == .shared ? "shared-database.json" : "private-database.json"
    return layout.syncStateDirectoryURL.appending(path: fileName, directoryHint: .notDirectory)
  }

  private func loadEngineState(scope: CKDatabase.Scope) -> CKSyncEngine.State.Serialization? {
    guard let data = try? Data(contentsOf: engineStateFileURL(scope: scope)) else { return nil }
    return try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
  }

  private func saveEngineState(
    _ serialization: CKSyncEngine.State.Serialization,
    scope: CKDatabase.Scope
  ) {
    guard let data = try? JSONEncoder().encode(serialization) else { return }
    try? data.write(to: engineStateFileURL(scope: scope), options: .atomic)
  }
}

private extension CKError {

  func isUnknownItem(for recordID: CKRecord.ID) -> Bool {
    if code == .unknownItem {
      return true
    }

    guard code == .partialFailure else { return false }
    if let partialErrors = userInfo[CKPartialErrorsByItemIDKey] as? [CKRecord.ID: any Error],
       let itemError = partialErrors[recordID] as? CKError {
      return itemError.code == .unknownItem
    }
    if let partialErrors = userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: any Error],
       let itemError = partialErrors[AnyHashable(recordID)] as? CKError {
      return itemError.code == .unknownItem
    }
    return false
  }
}
