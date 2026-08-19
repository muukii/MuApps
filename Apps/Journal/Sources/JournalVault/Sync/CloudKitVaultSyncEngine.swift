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
  private var backgroundFetchTask: Task<Void, Never>?
  private var foregroundSyncTasks: [VaultID: Task<Void, Never>] = [:]
  private var visiblePulseSubscriptionReconciliationTask: Task<Void, Never>?
  private var needsVisiblePulseSubscriptionReconciliation = false
  private var activityRetentionCoordinator: VaultActivityRetentionCoordinator?
  private let activityRetentionGeneration = VaultActivityRetentionGeneration()

  public init(
    containerIdentifier: String = VaultCloudKitContainer.identifier,
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

    // Load exact zone/scope routing before CKSyncEngine construction. Its
    // delegate can request a batch immediately, and a delete must fail closed
    // rather than escape during a descriptor-less startup window.
    await refreshDescriptors()

    engines[.private] = makeEngine(scope: .private)
    engines[.shared] = makeEngine(scope: .shared)

    // Build both sync engines with their explicit silent IDs before scheduling
    // a visible subscription. This prevents CKSyncEngine's automatic discovery
    // from adopting a Pulse alert subscription as its sync wake-up transport.
    scheduleVisiblePulseSubscriptionReconciliation()

    // Reseed the engines' pending sets from each vault's durable outbox. This
    // recovers work enqueued right before a crash and survives engine state
    // resets; re-adding an already pending change is a no-op. Startup only
    // stages this durable work so local launch routing never waits for a send.
    for descriptor in descriptors.values {
      await seedPendingChanges(
        for: descriptor,
        unstagingAll: true,
        shouldSendImmediately: false
      )
    }
    await resetEnginesIfPreReleaseRefetchRequested()

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
      await resetEnginesIfPreReleaseRefetchRequested()
      switch try await container.accountStatus() {
      case .available:
        try await discoverInitialVaultAvailability()
        await refreshDescriptors()
        scheduleBackgroundFetchAllChanges()
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
    } catch is CancellationError {
      return .unresolved("Initial iCloud recovery was cancelled.")
    } catch {
      return .resolvedWithDeferredCloudKit(error.localizedDescription)
    }
  }

  public func activate(_ vaultID: VaultID) async {
    await refreshDescriptorsIfUnknown(vaultID)
    await resetEnginesIfPreReleaseRefetchRequested()
    guard
      let descriptor = descriptors[vaultID],
      engines[databaseScope(for: descriptor)] != nil
    else {
      log.error("activate for unknown vault \(vaultID.uuidString, privacy: .public)")
      return
    }

    // The vault may have been written by an App Intent or Share extension. Such
    // writes cannot reach this process's local-mutation AsyncStream, so seed the
    // durable outbox before asking CKSyncEngine to fetch and send.
    await seedPendingChanges(
      for: descriptor,
      unstagingAll: false,
      shouldSendImmediately: false
    )
    scheduleForegroundSync(for: descriptor)
  }

  public func rescanPendingChanges() async {
    // App activation reaches this existing lifecycle seam. Retrying here keeps
    // a transient subscription failure from blocking content sync indefinitely.
    scheduleVisiblePulseSubscriptionReconciliation()
    await ensureDescriptorsLoaded()
    await refreshDescriptors()

    for descriptor in descriptors.values {
      await seedPendingChanges(for: descriptor, unstagingAll: false)
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
    if let existingShare = try await fetchZoneWideShare(
      zoneID: descriptor.zoneID, database: database)
    {
      share = existingShare
    } else {
      let newShare = CKShare(recordZoneID: descriptor.zoneID)
      newShare[CKShare.SystemFieldKey.title] = descriptor.title
      newShare.publicPermission = .none
      share = try await saveShare(newShare, database: database)
    }

    await applyFetchedShareSummary(share, descriptor: descriptor)

    return VaultSharePreparation(share: share, container: container)
  }

  public func existingShare(for vaultID: VaultID) async throws -> CKShare? {
    await ensureDescriptorsLoaded()
    await refreshDescriptorsIfUnknown(vaultID)

    guard let descriptor = descriptors[vaultID] else {
      throw VaultSharePreparationError.vaultNotFound(vaultID)
    }

    let database = cloudDatabase(for: databaseScope(for: descriptor))
    let share = try await fetchZoneWideShare(zoneID: descriptor.zoneID, database: database)

    if let share {
      await applyFetchedShareSummary(share, descriptor: descriptor)
    } else {
      switch descriptor.ownership {
      case .owned:
        // The catalog believed the vault was shared but no share exists
        // remotely (stopped from another device); self-correct the summary.
        await clearShareSummary(for: descriptor)
      case .participant:
        // A participant vault without a reachable share is about to disappear
        // through the zone-deletion path; don't touch the summary here.
        break
      }
    }
    return share
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

    // The accepted share carries the participant roster and this user's real
    // permission; without this the catalog would keep the materialized
    // read-write default even for read-only invites.
    if let acceptedVaultID, let descriptor = descriptors[acceptedVaultID] {
      await applyFetchedShareSummary(acceptedShare, descriptor: descriptor)
    }

    return VaultShareAcceptance(share: acceptedShare, vaultID: acceptedVaultID)
  }

  public func deleteVault(_ descriptor: VaultDescriptor) async throws {
    await start()
    await refreshDescriptorsIfUnknown(descriptor.vaultID)

    guard let currentDescriptor = descriptors[descriptor.vaultID] else {
      throw VaultDeletionError.vaultNotFound(descriptor.vaultID)
    }

    let scope = databaseScope(for: currentDescriptor)
    guard let engine = engines[scope] else {
      throw VaultDeletionError.cloudKitUnavailable
    }

    // The zone delete is the whole vault delete. Drop queued record work for
    // this zone before the direct CloudKit call so stale saves cannot race the
    // user's destructive action.
    removeEnginePendingChanges(for: currentDescriptor, engine: engine)

    do {
      _ = try await cloudDatabase(for: scope).deleteRecordZone(withID: currentDescriptor.zoneID)
    } catch let error as CKError where error.isMissingZone {
      // A local-only vault, an already-deleted vault, or a revoked shared zone
      // is already gone remotely; local cleanup can continue.
    } catch {
      throw VaultDeletionError.deleteFailed(error.localizedDescription)
    }

    removeEnginePendingChanges(for: currentDescriptor, engine: engine)
    syncDatabases.removeValue(forKey: currentDescriptor.vaultID)
    descriptors.removeValue(forKey: currentDescriptor.vaultID)
  }

  // MARK: - CKSyncEngineDelegate

  public func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
    let scope = syncEngine.database.databaseScope

    switch event {
    case .stateUpdate(let update):
      // Engines are recreated after a state reset. A late state update from
      // the replaced instance must not restore its stale token over the new
      // compatibility envelope.
      guard Self.isCurrentEngine(syncEngine, currentEngine: engines[scope]) else {
        return
      }
      saveEngineState(update.stateSerialization, scope: scope)

    case .accountChange(let change):
      // Vault data outlives account changes locally for now; the sign-out
      // policy (wipe vs keep) is an open product decision.
      log.notice("account change: \(String(describing: change.changeType), privacy: .public)")
      // Invalidate synchronously before awaiting cancellation. An old account
      // query can otherwise return during this suspension and enqueue deletes
      // for a same-UUID zone in the new private account.
      activityRetentionGeneration.invalidate()
      await activityRetentionCoordinator?.cancelAll()
      scheduleVisiblePulseSubscriptionReconciliation()

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

    let eligiblePending = await removingUnknownOutboxDeletes(
      from: pending,
      databaseScope: syncEngine.database.databaseScope,
      engine: syncEngine
    )
    guard eligiblePending.isEmpty == false else { return nil }

    // CKSyncEngine persists a set-like pending state and does not promise to
    // preserve the array order used while seeding it. Reapply each vault
    // outbox's content -> Activity -> Pulse priority at batch handoff. This is
    // only a local presentation preference: CloudKit can still commit distinct
    // records in another order, so Pulse remains a generic attention signal.
    let orderedPending = await orderedBatchChanges(
      eligiblePending,
      databaseScope: syncEngine.database.databaseScope
    )
    let batchPending = Self.limitingDeleteChanges(orderedPending)
    guard batchPending.isEmpty == false else { return nil }

    return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: batchPending) { recordID in
      await self.record(for: recordID, engine: syncEngine)
    }
  }

  /// Classifies every engine delete before it can enter an outgoing batch.
  ///
  /// A confirmed future-type row is removed from engine state but retained in
  /// the durable outbox. Missing routing or a failed lookup is indeterminate:
  /// the delete is omitted now and stays engine-pending for a later retry.
  private func removingUnknownOutboxDeletes(
    from pendingChanges: [CKSyncEngine.PendingRecordZoneChange],
    databaseScope: CKDatabase.Scope,
    engine: CKSyncEngine
  ) async -> [CKSyncEngine.PendingRecordZoneChange] {
    var decisions: [CKRecord.ID: OutboxDeleteSafetyDecision] = [:]

    for pendingChange in pendingChanges {
      guard case .deleteRecord(let recordID) = pendingChange else { continue }
      do {
        guard
          let database = try syncDatabase(
            forZone: recordID.zoneID,
            scope: databaseScope
          )
        else {
          decisions[recordID] = .indeterminate
          continue
        }
        decisions[recordID] =
          try await database.hasUnknownDeletePendingMutation(
            recordName: recordID.recordName
          ) ? .unknownFutureType : .eligible
      } catch {
        decisions[recordID] = .indeterminate
      }
    }

    let unknownDeleteRecordIDs = Set(
      decisions.compactMap { recordID, decision in
        decision == .unknownFutureType ? recordID : nil
      }
    )
    let indeterminateDeleteCount = decisions.values.count { $0 == .indeterminate }

    let filteredPendingChanges = Self.filteringOutboxDeletes(
      pendingChanges,
      decisions: decisions
    )
    if unknownDeleteRecordIDs.isEmpty == false {
      let removedPendingChanges = pendingChanges.filter { change in
        switch change {
        case .deleteRecord(let recordID):
          unknownDeleteRecordIDs.contains(recordID)
        case .saveRecord:
          false
        @unknown default:
          false
        }
      }
      engine.state.remove(pendingRecordZoneChanges: removedPendingChanges)
      log.notice(
        "retained \(unknownDeleteRecordIDs.count, privacy: .public) unknown outbox delete(s) for a future Tinycurve build"
      )
    }
    if indeterminateDeleteCount > 0 {
      log.notice(
        "deferred \(indeterminateDeleteCount, privacy: .public) outbox delete(s) until exact routing can be confirmed"
      )
    }
    return filteredPendingChanges
  }

  /// A delete is eligible only after both exact routing and durable-outbox
  /// classification succeed. Missing decisions intentionally fail closed.
  enum OutboxDeleteSafetyDecision: Equatable, Sendable {
    case eligible
    case unknownFutureType
    case indeterminate
  }

  /// Filters a persisted engine batch without changing durable outbox rows.
  /// Unknown future deletes are removed from engine state by the caller;
  /// indeterminate deletes stay engine-pending for a later, routable batch.
  static func filteringOutboxDeletes(
    _ pendingChanges: [CKSyncEngine.PendingRecordZoneChange],
    decisions: [CKRecord.ID: OutboxDeleteSafetyDecision]
  ) -> [CKSyncEngine.PendingRecordZoneChange] {
    pendingChanges.filter { pendingChange in
      switch pendingChange {
      case .deleteRecord(let recordID):
        decisions[recordID] == .eligible
      case .saveRecord:
        true
      @unknown default:
        false
      }
    }
  }

  /// Maximum number of record deletes handed to one CKSyncEngine batch.
  ///
  /// Saves are deliberately not counted: a foreground authored change can
  /// proceed beside history cleanup, while large retention windows drain over
  /// successive engine batches without a single delete burst dominating one
  /// outgoing operation.
  static let maximumDeletesPerBatch = 200

  /// Preserves the caller's durable ordering while allowing at most the given
  /// number of delete requests through. The remaining deletes stay pending in
  /// CKSyncEngine and are offered to its next batch unchanged.
  static func limitingDeleteChanges(
    _ pendingChanges: [CKSyncEngine.PendingRecordZoneChange],
    maximumDeletes: Int = maximumDeletesPerBatch
  ) -> [CKSyncEngine.PendingRecordZoneChange] {
    var includedDeleteCount = 0
    let deleteLimit = max(0, maximumDeletes)

    return pendingChanges.filter { pendingChange in
      guard case .deleteRecord = pendingChange else { return true }
      guard includedDeleteCount < deleteLimit else { return false }
      includedDeleteCount += 1
      return true
    }
  }

  /// Returns the engine's current pending changes in durable per-vault outbox
  /// order. Changes whose local row disappeared since the engine was seeded
  /// retain the engine's existing relative order and are handled by its normal
  /// stale-change cleanup path.
  private func orderedBatchChanges(
    _ pending: [CKSyncEngine.PendingRecordZoneChange],
    databaseScope: CKDatabase.Scope
  ) async -> [CKSyncEngine.PendingRecordZoneChange] {
    var rankByChange: [CKSyncEngine.PendingRecordZoneChange: Int] = [:]
    var nextRank = 0
    var visitedZoneIDs = Set<CKRecordZone.ID>()

    for change in pending {
      guard let recordID = Self.recordID(for: change) else { continue }
      guard visitedZoneIDs.insert(recordID.zoneID).inserted else { continue }
      guard
        let database = try? syncDatabase(forZone: recordID.zoneID, scope: databaseScope)
      else {
        continue
      }
      guard let outbox = try? await database.pendingChanges() else { continue }

      for mutation in outbox {
        let outboxRecordID = CKRecord.ID(
          recordName: mutation.recordName,
          zoneID: recordID.zoneID
        )
        let outboxChange: CKSyncEngine.PendingRecordZoneChange
        switch mutation.kind {
        case .save:
          outboxChange = .saveRecord(outboxRecordID)
        case .delete:
          outboxChange = .deleteRecord(outboxRecordID)
        }

        guard pending.contains(outboxChange) else { continue }
        rankByChange[outboxChange] = nextRank
        nextRank += 1
      }
    }

    return pending.enumerated().sorted { lhs, rhs in
      let lhsRank = rankByChange[lhs.element] ?? .max
      let rhsRank = rankByChange[rhs.element] ?? .max
      if lhsRank != rhsRank {
        return lhsRank < rhsRank
      }
      return lhs.offset < rhs.offset
    }.map(\.element)
  }

  private static func recordID(
    for change: CKSyncEngine.PendingRecordZoneChange
  ) -> CKRecord.ID? {
    switch change {
    case .saveRecord(let recordID), .deleteRecord(let recordID):
      recordID
    @unknown default:
      nil
    }
  }

  // MARK: - Outgoing

  /// Builds the record for one pending save, or drops the pending change when
  /// the row no longer exists (deleted before its upload ran).
  private func record(for recordID: CKRecord.ID, engine: CKSyncEngine) async -> CKRecord? {
    do {
      guard
        let database = try syncDatabase(
          forZone: recordID.zoneID,
          scope: engine.database.databaseScope
        )
      else {
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
    let databaseScope = engine.database.databaseScope

    for record in sent.savedRecords {
      do {
        guard
          let database = try syncDatabase(
            forZone: record.recordID.zoneID,
            scope: databaseScope
          )
        else {
          continue
        }
        let outcome = try await database.handleSavedRecord(record)
        if outcome.didAcknowledgeLocalActivity {
          await scheduleActivityRetention(
            for: record.recordID.zoneID,
            scope: databaseScope
          )
        }
        if outcome.didMakeSharedWithYouNoticeReady,
          let vaultID = VaultID(zoneName: record.recordID.zoneID.zoneName)
        {
          // `handleSavedRecord` has already committed the waiting-to-ready
          // transition under the vault transaction lock. Broadcast only after
          // that durable boundary; remote imports and duplicate ACKs report a
          // false outcome and never trigger a Shared with You post.
          registry.notifySharedWithYouNoticeReady(for: vaultID)
        }
      } catch {
        log.error("confirm save failed \(record.recordID.recordName, privacy: .public): \(error)")
      }
    }

    for failure in sent.failedRecordSaves {
      let recordID = failure.record.recordID
      guard
        let database = try? syncDatabase(forZone: recordID.zoneID, scope: databaseScope)
      else {
        log.notice(
          "ignored stale save callback for unroutable zone \(recordID.zoneID.zoneName, privacy: .public)"
        )
        continue
      }

      switch failure.error.code {
      case .serverRecordChanged:
        // Conflict. Policy lives in VaultSyncDatabase.handleServerRecordChanged
        // (local wins); re-queue so the merged save goes out again.
        if let serverRecord = failure.error.serverRecord {
          try? await database.handleServerRecordChanged(serverRecord: serverRecord)
          engine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
        }

      case .zoneNotFound, .userDeletedZone:
        // First save into a fresh vault (zones are created lazily) or the zone
        // vanished — (re)create it and retry the record.
        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: recordID.zoneID))])
        engine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
        try? await database.unstage(recordName: recordID.recordName)

      default:
        // Transient failures (network, throttling) are retried by CKSyncEngine
        // itself; unstage so the row re-stages into the retry batch.
        try? await database.unstage(recordName: recordID.recordName)
        log.error("record save failed \(recordID.recordName, privacy: .public): \(failure.error)")
      }
    }

    for recordID in sent.deletedRecordIDs {
      try? await syncDatabase(forZone: recordID.zoneID, scope: databaseScope)?
        .handleCompletedDelete(recordName: recordID.recordName)
    }

    for (recordID, error) in sent.failedRecordDeletes {
      switch error.code {
      case .unknownItem, .zoneNotFound, .userDeletedZone:
        // Nothing to delete remotely — the tombstone has served its purpose.
        try? await syncDatabase(forZone: recordID.zoneID, scope: databaseScope)?
          .handleCompletedDelete(recordName: recordID.recordName)
      default:
        log.error("record delete failed \(recordID.recordName, privacy: .public): \(error)")
      }
    }
  }

  // MARK: - Activity retention

  /// Coalesces cleanup after a locally authored Activity reaches CloudKit.
  ///
  /// This is intentionally an acknowledgement-only trigger. Incoming Activity
  /// imports are observations, and duplicate save callbacks must not create
  /// independent retention tasks or mutate Activity/Pulse/notice state.
  private func scheduleActivityRetention(
    for zoneID: CKRecordZone.ID,
    scope: CKDatabase.Scope
  ) async {
    guard let retentionZone = activityRetentionZone(for: zoneID, scope: scope) else { return }
    let generation = activityRetentionGeneration.capture()

    let coordinator: VaultActivityRetentionCoordinator
    if let existing = activityRetentionCoordinator {
      coordinator = existing
    } else {
      let newCoordinator = VaultActivityRetentionCoordinator {
        [weak self] retentionZone, scheduledGeneration in
        guard let self else { return }
        await self.performActivityRetention(
          for: retentionZone,
          generation: scheduledGeneration
        )
      }
      activityRetentionCoordinator = newCoordinator
      coordinator = newCoordinator
    }
    await coordinator.schedule(retentionZone, generation: generation)
  }

  /// Queries one exact server zone and turns only the oldest excess Activities
  /// into durable tombstones. Any query/page/result failure exits before the
  /// SwiftData transaction, so a later acknowledgement can retry safely.
  private func performActivityRetention(
    for retentionZone: VaultActivityRetentionZone,
    generation: UInt64
  ) async {
    let zoneID = retentionZone.cloudKitZoneID
    guard
      Task.isCancelled == false,
      activityRetentionGeneration.isCurrent(generation),
      descriptor(forActivityRetentionZone: retentionZone) != nil
    else {
      return
    }

    do {
      let serverCandidates = try await VaultActivityRetentionCloudKitQuery(
        database: cloudDatabase(for: retentionZone.cloudKitDatabaseScope)
      ).activityCandidates(in: zoneID)
      guard
        Task.isCancelled == false,
        activityRetentionGeneration.isCurrent(generation)
      else {
        return
      }
      let deletionCandidates = VaultActivityRetentionPolicy.deletionCandidates(
        from: serverCandidates
      )
      guard deletionCandidates.isEmpty == false else { return }

      // Catalog membership and ownership can change while the network query is
      // suspended. Recheck before opening the store or seeding the engine.
      guard let currentDescriptor = descriptor(forActivityRetentionZone: retentionZone) else {
        return
      }
      let database = try syncDatabase(for: currentDescriptor)
      guard
        let outcome = try await database.enqueueActivityRetentionDeletes(
          deletionCandidates,
          ifCurrent: activityRetentionGeneration,
          generation: generation
        ),
        activityRetentionGeneration.isCurrent(generation),
        Task.isCancelled == false
      else {
        return
      }
      guard outcome.hasDeleteWork else { return }
      await seedPendingChanges(for: currentDescriptor, unstagingAll: false)
    } catch is CancellationError {
      return
    } catch {
      log.error(
        "Activity retention failed for \(zoneID.zoneName, privacy: .public): \(error)"
      )
    }
  }

  /// Resolves a retention scheduler key back to current catalog state without
  /// ever broadening a query beyond its original scope and exact zone ID.
  private func descriptor(
    forActivityRetentionZone retentionZone: VaultActivityRetentionZone
  ) -> VaultDescriptor? {
    Self.exactDescriptor(
      for: retentionZone.cloudKitZoneID,
      scope: retentionZone.cloudKitDatabaseScope,
      in: descriptors
    )
  }

  private func activityRetentionZone(
    for zoneID: CKRecordZone.ID,
    scope: CKDatabase.Scope
  ) -> VaultActivityRetentionZone? {
    guard Self.exactDescriptor(for: zoneID, scope: scope, in: descriptors) != nil else {
      return nil
    }
    return VaultActivityRetentionZone(scope: scope, zoneID: zoneID)
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
      await deleteLocalVaultAfterRemoteZoneRemoval(
        zoneID: deletion.zoneID,
        scope: scope,
        reason: String(describing: deletion.reason)
      )
    }
  }

  /// Applies a remote zone deletion locally: owner deleted the vault, a share
  /// was revoked, or the user removed the accepted shared zone elsewhere.
  private func deleteLocalVaultAfterRemoteZoneRemoval(
    zoneID: CKRecordZone.ID,
    scope: CKDatabase.Scope,
    reason: String
  ) async {
    guard
      let descriptor = Self.exactDescriptor(for: zoneID, scope: scope, in: descriptors)
    else {
      log.notice(
        "ignored stale zone deletion for unroutable zone \(zoneID.zoneName, privacy: .public)"
      )
      return
    }
    let vaultID = descriptor.vaultID

    if let engine = engines[scope] {
      removeEnginePendingChanges(for: descriptor, engine: engine)
    }

    syncDatabases.removeValue(forKey: vaultID)
    registry.discardStore(for: vaultID)

    do {
      try layout.removeVaultDirectory(for: vaultID)
    } catch {
      log.error(
        "remove local vault directory failed \(vaultID.uuidString, privacy: .public): \(error)")
    }

    do {
      try await catalog.deleteVault(vaultID: vaultID)
      descriptors.removeValue(forKey: vaultID)
      log.info(
        """
        vault zone removed remotely \
        (\(reason, privacy: .public)): \
        \(vaultID.uuidString, privacy: .public)
        """
      )
    } catch {
      log.error("remove local catalog row failed \(vaultID.uuidString, privacy: .public): \(error)")
    }
  }

  private func handleFetchedRecordZoneChanges(
    _ changes: CKSyncEngine.Event.FetchedRecordZoneChanges,
    scope: CKDatabase.Scope
  ) async {
    // The zone-wide `CKShare` is catalog metadata, not vault content: split it
    // out before import so share creation, participant changes, and share
    // deletion on other devices reach the share summary instead of being
    // dropped by the content record-type filter.
    var fetchedSharesByZone: [CKRecordZone.ID: CKShare] = [:]
    var modificationsByZone: [CKRecordZone.ID: [CKRecord]] = [:]
    for modification in changes.modifications {
      let record = modification.record
      if let share = record as? CKShare {
        fetchedSharesByZone[record.recordID.zoneID] = share
        continue
      }
      modificationsByZone[record.recordID.zoneID, default: []].append(record)
    }

    var deletedShareZoneIDs: Set<CKRecordZone.ID> = []
    var deletionsByZone: [CKRecordZone.ID: [RecordDeletion]] = [:]
    for deletion in changes.deletions {
      if deletion.recordType == CKRecord.SystemType.share {
        deletedShareZoneIDs.insert(deletion.recordID.zoneID)
        continue
      }
      deletionsByZone[deletion.recordID.zoneID, default: []].append(
        RecordDeletion(recordName: deletion.recordID.recordName, recordType: deletion.recordType)
      )
    }

    let zoneIDs = Set(modificationsByZone.keys)
      .union(deletionsByZone.keys)
      .union(fetchedSharesByZone.keys)
      .union(deletedShareZoneIDs)
    for zoneID in zoneIDs {
      guard let vaultID = VaultID(zoneName: zoneID.zoneName) else { continue }
      await materializeVaultIfNeeded(vaultID: vaultID, zoneID: zoneID, scope: scope)
      guard
        let descriptor = Self.exactDescriptor(for: zoneID, scope: scope, in: descriptors)
      else {
        continue
      }

      let modifications = modificationsByZone[zoneID] ?? []
      let deletions = deletionsByZone[zoneID] ?? []
      if modifications.isEmpty == false || deletions.isEmpty == false {
        do {
          let database = try syncDatabase(for: descriptor)
          let outcome = try await database.importChanges(
            modifications: modifications,
            deletions: deletions
          )

          if let title = outcome.importedVaultTitle {
            try? await catalog.applyImportedVaultInfo(
              vaultID: vaultID,
              title: title,
              icon: outcome.importedVaultIcon
            )
          }
          try? await catalog.noteVaultSynced(vaultID)

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

      if let share = fetchedSharesByZone[zoneID] {
        await applyFetchedShareSummary(share, descriptor: descriptor)
      } else if deletedShareZoneIDs.contains(zoneID), descriptor.ownership == .owned {
        // The owner stopped sharing, possibly on another device. Participants
        // never see this record deletion — their whole zone disappears via the
        // database-change path instead.
        await clearShareSummary(for: descriptor)
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
  ///
  /// Startup and foreground activation stage work without awaiting CloudKit;
  /// their owned foreground task performs the send. Mutation and explicit
  /// operations may still request an immediate send after staging.
  private func seedPendingChanges(
    for descriptor: VaultDescriptor,
    unstagingAll: Bool,
    shouldSendImmediately: Bool = true
  ) async {
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
      if shouldSendImmediately {
        await sendSeededPendingChanges(engine: engine, vaultID: descriptor.vaultID)
      }
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

  private func cloudDatabase(for scope: CKDatabase.Scope) -> CKDatabase {
    scope == .shared ? container.sharedCloudDatabase : container.privateCloudDatabase
  }

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

  /// Resolves a callback only when its full CloudKit identity matches current
  /// catalog state. Zone UUID alone is insufficient across account changes or
  /// when a stale shared-owner callback arrives after rejoining the same vault.
  static func exactDescriptor(
    for zoneID: CKRecordZone.ID,
    scope: CKDatabase.Scope,
    in descriptors: [VaultID: VaultDescriptor]
  ) -> VaultDescriptor? {
    guard
      scope == .private || scope == .shared,
      let vaultID = VaultID(zoneName: zoneID.zoneName),
      let descriptor = descriptors[vaultID],
      descriptor.zoneID == zoneID
    else {
      return nil
    }

    switch descriptor.ownership {
    case .owned:
      guard scope == .private else { return nil }
    case .participant:
      guard scope == .shared else { return nil }
    }
    return descriptor
  }

  private func syncDatabase(
    forZone zoneID: CKRecordZone.ID,
    scope: CKDatabase.Scope
  ) throws -> VaultSyncDatabase? {
    guard let descriptor = Self.exactDescriptor(for: zoneID, scope: scope, in: descriptors) else {
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

  private func removeEnginePendingChanges(
    for descriptor: VaultDescriptor,
    engine: CKSyncEngine
  ) {
    let zoneID = descriptor.zoneID
    let recordChanges = engine.state.pendingRecordZoneChanges.filter { change in
      switch change {
      case .saveRecord(let recordID), .deleteRecord(let recordID):
        return recordID.zoneID == zoneID
      @unknown default:
        return false
      }
    }
    if recordChanges.isEmpty == false {
      engine.state.remove(pendingRecordZoneChanges: recordChanges)
    }

    let databaseChanges = engine.state.pendingDatabaseChanges.filter { change in
      switch change {
      case .saveZone(let zone):
        return zone.zoneID == zoneID
      case .deleteZone(let deletedZoneID):
        return deletedZoneID == zoneID
      @unknown default:
        return false
      }
    }
    if databaseChanges.isEmpty == false {
      engine.state.remove(pendingDatabaseChanges: databaseChanges)
    }
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
    } catch let error as CKError where error.isUnknownItem(for: recordID) || error.isMissingZone {
      // No share record, or the zone itself doesn't exist yet (a local-only
      // vault whose first upload hasn't created it). Either way: not shared.
      return nil
    }
  }

  /// Mirrors a fetched zone-wide share into the catalog's lightweight summary.
  ///
  /// This is the single write path from a live `CKShare` to display state, so
  /// every discovery/fetch/accept route reports participants the same way.
  private func applyFetchedShareSummary(_ share: CKShare, descriptor: VaultDescriptor) async {
    let permission: VaultPermissionSummary
    switch descriptor.ownership {
    case .owned:
      permission = .owner
    case .participant:
      // `.unknown` / `.none` should not appear on an accepted participant's
      // own entry; degrade to the materialized read-write default if they do.
      let participantPermission = share.currentUserParticipant?.permission ?? .readWrite
      switch participantPermission {
      case .readOnly:
        permission = .readOnly
      case .readWrite, .none, .unknown:
        permission = .readWrite
      @unknown default:
        permission = .readWrite
      }
    }

    do {
      try await catalog.applyShareInfo(
        vaultID: descriptor.vaultID,
        isShared: true,
        shareURL: share.url,
        shareRecordName: share.recordID.recordName,
        participantCount: max(1, share.participants.count),
        permission: permission
      )
    } catch {
      log.error(
        "apply share summary failed \(descriptor.vaultID.uuidString, privacy: .public): \(error)"
      )
    }
  }

  /// Resets an owned vault's summary to the unshared state after the share
  /// record disappeared remotely.
  private func clearShareSummary(for descriptor: VaultDescriptor) async {
    do {
      try await catalog.applyShareInfo(
        vaultID: descriptor.vaultID,
        isShared: false,
        shareURL: nil,
        shareRecordName: nil,
        participantCount: 1,
        permission: .owner
      )
    } catch {
      log.error(
        "clear share summary failed \(descriptor.vaultID.uuidString, privacy: .public): \(error)"
      )
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

  private func discoverInitialVaultAvailability() async throws {
    await resetEnginesIfPreReleaseRefetchRequested()

    try await discoverInitialVaults(scope: .private)
    try await discoverInitialVaults(scope: .shared)
  }

  /// Performs the launch-blocking CloudKit discovery pass without fetching card
  /// content or asset-backed attachment resources. Full record import is kicked
  /// after launch routing resolves so large media does not hold the loading
  /// screen hostage.
  private func discoverInitialVaults(scope: CKDatabase.Scope) async throws {
    let database = cloudDatabase(for: scope)
    let zones = try await database.allRecordZones()

    for zone in zones {
      try Task.checkCancellation()

      let zoneID = zone.zoneID
      guard let vaultID = VaultID(zoneName: zoneID.zoneName) else { continue }
      await materializeVaultIfNeeded(vaultID: vaultID, zoneID: zoneID, scope: scope)
      try await applyInitialVaultInfoIfAvailable(
        vaultID: vaultID,
        zoneID: zoneID,
        database: database
      )
      try await applyInitialShareSummary(
        vaultID: vaultID,
        zoneID: zoneID,
        database: database
      )
    }
  }

  /// Rediscovers the zone-wide share during initial discovery so a reinstall or
  /// the user's other device shows correct sharing state before the first
  /// engine fetch delivers the share record.
  private func applyInitialShareSummary(
    vaultID: VaultID,
    zoneID: CKRecordZone.ID,
    database: CKDatabase
  ) async throws {
    guard let descriptor = descriptors[vaultID] else { return }

    if let share = try await fetchZoneWideShare(zoneID: zoneID, database: database) {
      await applyFetchedShareSummary(share, descriptor: descriptor)
    } else if descriptor.ownership == .owned {
      await clearShareSummary(for: descriptor)
    }
  }

  /// Reads only the lightweight title record needed to show the vault picker.
  ///
  /// This direct fetch deliberately does not advance `CKSyncEngine` change
  /// tokens. The later background engine fetch may import the same `VaultInfo`
  /// again, which is fine because catalog title application is idempotent.
  private func applyInitialVaultInfoIfAvailable(
    vaultID: VaultID,
    zoneID: CKRecordZone.ID,
    database: CKDatabase
  ) async throws {
    let recordID = CKRecord.ID(recordName: vaultID.uuidString, zoneID: zoneID)

    do {
      let record = try await database.record(for: recordID)
      guard record.recordType == VaultRecordType.vaultInfo.rawValue else { return }
      try await catalog.applyImportedVaultInfo(
        vaultID: vaultID,
        title: VaultInfoRecord(record: record).title,
        icon: VaultRecordMapper.vaultIcon(from: record)
      )
    } catch let error as CKError where error.isUnknownItem(for: recordID) {
      log.info(
        "vault info missing during initial discovery \(vaultID.uuidString, privacy: .public)"
      )
    }
  }

  private func scheduleBackgroundFetchAllChanges() {
    guard backgroundFetchTask == nil else { return }
    backgroundFetchTask = Task { await self.runBackgroundFetchAllChanges() }
  }

  private func runBackgroundFetchAllChanges() async {
    defer { backgroundFetchTask = nil }

    do {
      try await fetchAllChanges()
    } catch is CancellationError {
      log.debug("background fetch cancelled")
    } catch {
      log.error("background fetch failed: \(error)")
    }
  }

  private func fetchAllChanges() async throws {
    await resetEnginesIfPreReleaseRefetchRequested()

    if let privateEngine = engines[.private] {
      try await privateEngine.fetchChanges(.init(scope: .all))
    }

    if let sharedEngine = engines[.shared] {
      try await sharedEngine.fetchChanges(.init(scope: .all))
    }
  }

  private func scheduleForegroundSync(for descriptor: VaultDescriptor) {
    let vaultID = descriptor.vaultID
    guard foregroundSyncTasks[vaultID] == nil else { return }

    foregroundSyncTasks[vaultID] = Task {
      await self.runForegroundSync(vaultID: vaultID)
    }
  }

  private func runForegroundSync(vaultID: VaultID) async {
    defer { foregroundSyncTasks[vaultID] = nil }

    await refreshDescriptorsIfUnknown(vaultID)
    guard
      let descriptor = descriptors[vaultID],
      let engine = engines[databaseScope(for: descriptor)]
    else {
      log.error("foreground sync for unknown vault \(vaultID.uuidString, privacy: .public)")
      return
    }

    if backgroundFetchTask == nil {
      do {
        try await engine.fetchChanges(.init(scope: .zoneIDs([descriptor.zoneID])))
      } catch is CancellationError {
        log.debug("foreground fetch cancelled \(vaultID.uuidString, privacy: .public)")
      } catch {
        log.error("foreground fetch failed \(vaultID.uuidString, privacy: .public): \(error)")
      }
    }

    do {
      let database = try syncDatabase(for: descriptor)
      if try await database.hasPendingMutations() {
        try await engine.sendChanges()
      }
    } catch is CancellationError {
      log.debug("foreground send cancelled \(vaultID.uuidString, privacy: .public)")
    } catch {
      log.error("foreground send failed \(vaultID.uuidString, privacy: .public): \(error)")
    }
  }

  // MARK: - Visible Pulse subscription reconciliation

  /// Coalesces lifecycle requests while preserving a request that arrives during
  /// an in-flight CloudKit call. The work remains separate from Vault record
  /// synchronization, so a subscription error never delays content recovery.
  private func scheduleVisiblePulseSubscriptionReconciliation() {
    needsVisiblePulseSubscriptionReconciliation = true
    guard visiblePulseSubscriptionReconciliationTask == nil else { return }

    visiblePulseSubscriptionReconciliationTask = Task {
      await self.runVisiblePulseSubscriptionReconciliation()
    }
  }

  private func runVisiblePulseSubscriptionReconciliation() async {
    defer { visiblePulseSubscriptionReconciliationTask = nil }

    while needsVisiblePulseSubscriptionReconciliation {
      needsVisiblePulseSubscriptionReconciliation = false
      await reconcileVisiblePulseSubscriptions()
    }
  }

  private func reconcileVisiblePulseSubscriptions() async {
    for scope: CKDatabase.Scope in [.private, .shared] {
      let store = CloudKitDatabaseSubscriptionStore(database: cloudDatabase(for: scope))
      let reconciler = VaultNotificationPulseSubscriptionReconciler(store: store)
      let scopeName = scope == .private ? "private" : "shared"

      do {
        let outcome = try await reconciler.reconcile(databaseScope: scope)
        log.debug(
          "visible Pulse subscription reconciliation for \(scopeName, privacy: .public): \(outcome.rawValue, privacy: .public)"
        )
      } catch is CancellationError {
        log.debug("visible Pulse subscription reconciliation cancelled")
        return
      } catch {
        // Do not turn a server-subscription failure into a Vault sync failure.
        // Startup, account change, and app activation will request another pass.
        log.error(
          "visible Pulse subscription reconciliation failed for \(scopeName, privacy: .public): \(error)"
        )
      }
    }
  }

  // MARK: - Engine construction & state persistence

  private func makeEngine(scope: CKDatabase.Scope) -> CKSyncEngine {
    guard let subscriptionID = VaultSyncEngineSubscription.identifier(for: scope) else {
      preconditionFailure("Vault sync only supports private and shared CloudKit databases.")
    }

    var configuration = CKSyncEngine.Configuration(
      database: cloudDatabase(for: scope),
      stateSerialization: loadEngineState(scope: scope),
      delegate: self
    )
    configuration.subscriptionID = subscriptionID
    return CKSyncEngine(configuration)
  }

  private func engineStateFileURL(scope: CKDatabase.Scope) -> URL {
    let fileName = scope == .shared ? "shared-database.json" : "private-database.json"
    return layout.syncStateDirectoryURL.appending(path: fileName, directoryHint: .notDirectory)
  }

  private func loadEngineState(scope: CKDatabase.Scope) -> CKSyncEngine.State.Serialization? {
    guard let data = try? Data(contentsOf: engineStateFileURL(scope: scope)) else { return nil }
    switch VaultSyncEngineStateEnvelope.restore(
      from: data,
      as: CKSyncEngine.State.Serialization.self
    ) {
    case .restored(let serialization):
      return serialization

    case .requiresFullRefetch:
      // Persist the current empty header before constructing the engine. This
      // prevents an unchanged legacy/mismatched file from causing an
      // invalidation loop if the process exits during the first refetch.
      saveEmptyEngineStateEnvelope(
        scope: scope
      )
      return nil
    }
  }

  private func saveEngineState(
    _ serialization: CKSyncEngine.State.Serialization,
    scope: CKDatabase.Scope
  ) {
    guard
      let data = try? VaultSyncEngineStateEnvelope.current(serialization: serialization)
        .encoded()
    else {
      return
    }
    try? data.write(to: engineStateFileURL(scope: scope), options: .atomic)
  }

  /// Persists a current, intentionally empty envelope after a token mismatch.
  private func saveEmptyEngineStateEnvelope(scope: CKDatabase.Scope) {
    guard let data = try? VaultSyncEngineStateEnvelope.emptyCurrent.encoded() else { return }
    try? data.write(to: engineStateFileURL(scope: scope), options: .atomic)
  }

  /// Rejects state writes emitted by a `CKSyncEngine` instance that has already
  /// been replaced for the same CloudKit database scope.
  static func isCurrentEngine<Engine: AnyObject>(
    _ eventEngine: Engine,
    currentEngine: Engine?
  ) -> Bool {
    guard let currentEngine else { return false }
    return eventEngine === currentEngine
  }

  /// A pre-release local store reset discards rows and media, so the next
  /// CloudKit fetch must not reuse old CKSyncEngine change tokens. Rebuild both
  /// database engines from empty state; CKSyncEngine will then rediscover zones
  /// and replay remote records into the fresh vault store.
  private func resetEnginesIfPreReleaseRefetchRequested() async {
    var didConsumeRequest = false

    for descriptor in descriptors.values {
      do {
        if try layout.consumePreReleaseCloudKitRefetchRequest(for: descriptor.vaultID) {
          didConsumeRequest = true
        }
      } catch {
        log.error(
          "consume pre-release refetch marker failed \(descriptor.vaultID.uuidString, privacy: .public): \(error)"
        )
      }
    }

    guard didConsumeRequest else { return }

    do {
      try layout.resetCloudKitSyncStateFiles()
    } catch {
      log.error("reset CKSyncEngine state files failed: \(error)")
    }

    syncDatabases.removeAll()
    engines[.private] = makeEngine(scope: .private)
    engines[.shared] = makeEngine(scope: .shared)
    await refreshDescriptors()

    for descriptor in descriptors.values {
      await seedPendingChanges(
        for: descriptor,
        unstagingAll: true,
        shouldSendImmediately: false
      )
    }

    log.info("reset CKSyncEngine state for pre-release vault store recovery")
  }
}

extension CKError {

  fileprivate var isMissingZone: Bool {
    switch code {
    case .unknownItem, .zoneNotFound, .userDeletedZone:
      return true
    case .partialFailure:
      return partialErrorsContainMissingZone()
    default:
      return false
    }
  }

  fileprivate func isUnknownItem(for recordID: CKRecord.ID) -> Bool {
    if code == .unknownItem {
      return true
    }

    guard code == .partialFailure else { return false }
    if let partialErrors = userInfo[CKPartialErrorsByItemIDKey] as? [CKRecord.ID: any Error],
      let itemError = partialErrors[recordID] as? CKError
    {
      return itemError.code == .unknownItem
    }
    if let partialErrors = userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: any Error],
      let itemError = partialErrors[AnyHashable(recordID)] as? CKError
    {
      return itemError.code == .unknownItem
    }
    return false
  }

  private func partialErrorsContainMissingZone() -> Bool {
    if let partialErrors = userInfo[CKPartialErrorsByItemIDKey] as? [CKRecordZone.ID: any Error] {
      return partialErrors.values.contains { error in
        (error as? CKError)?.isMissingZone == true
      }
    }
    if let partialErrors = userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: any Error] {
      return partialErrors.values.contains { error in
        (error as? CKError)?.isMissingZone == true
      }
    }
    return false
  }
}
