import CloudKit
import Foundation
import JournalModel
import OSLog

/// Custom CloudKit sync for attachment **files** — the bytes that SwiftData's
/// `.automatic` mirroring deliberately does not carry (see `Attachment`).
///
/// It runs in the app process **alongside** the automatic mirroring, but in its
/// own private-database zone (`Media`), so the two never collide: `.automatic`
/// owns the `Card` / `Tag` / `Attachment` rows and their thumbnails, while this
/// owns one immutable `MediaFile` record (a single `CKAsset`) per attachment. The
/// join key is the attachment's `UUID`, which is simultaneously the SwiftData
/// `Attachment.id`, the on-disk file name (`JournalStore.mediaDirectory/<uuid>`),
/// and the CloudKit record name — so this engine never needs to read the store.
///
/// Records are **immutable** (created once, deleted once) to avoid CKSyncEngine's
/// behavior of re-uploading every `CKAsset` on a record whenever any field
/// changes. The local file is the source of truth; the `CKAsset` is only transport.
///
/// Ownership note: `CKSyncEngine` retains its delegate (this actor) and this actor
/// retains the engine — an intentional cycle for an app-lifetime singleton.
///
/// First-cut scope. Deferred (documented in the team notes): crash-safe recompute
/// of pending uploads from disk, content-hash dedup, download-on-demand UI, and a
/// richer conflict / retry policy beyond what CKSyncEngine already retries.
public actor MediaSyncEngine: CKSyncEngineDelegate {

  private static let zoneName = "Media"
  private static let recordType = "MediaFile"
  private static let assetField = "asset"
  private static let stateFileName = "media-engine.json"

  private let container: CKContainer
  private let savedState: CKSyncEngine.State.Serialization?
  private let log = Logger(subsystem: "app.muukii.journal", category: "MediaSync")

  private lazy var engine: CKSyncEngine = CKSyncEngine(
    .init(
      database: container.privateCloudDatabase,
      stateSerialization: savedState,
      delegate: self
    )
  )

  public init(containerIdentifier: String = "iCloud.app.muukii.journal") {
    self.container = CKContainer(identifier: containerIdentifier)
    self.savedState = Self.loadState()
  }

  /// Brings the engine up. Call once at launch. The engine is `lazy` so that
  /// `self` is a fully-formed delegate before `CKSyncEngine` captures it; on the
  /// very first run (no saved state) the custom zone is queued for creation.
  public func start() {
    if savedState == nil {
      engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneName: Self.zoneName))])
    } else {
      _ = engine  // touch the lazy engine so it resumes syncing from saved state
    }
  }

  /// Queues an attachment's file for upload. The host calls this right after
  /// `JournalStore.attachData`/`attachFile` writes the file and saves the row.
  public func enqueueUpload(attachmentID: UUID) {
    engine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID(for: attachmentID))])
  }

  /// Queues an attachment's remote file for deletion. The local file is removed by
  /// `JournalStore.deleteAttachment` / `reconcileOrphanFiles`; this removes the
  /// CloudKit copy.
  public func enqueueDelete(attachmentID: UUID) {
    engine.state.add(pendingRecordZoneChanges: [.deleteRecord(recordID(for: attachmentID))])
  }

  // MARK: - CKSyncEngineDelegate

  public func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
    switch event {
    case .stateUpdate(let update):
      saveState(update.stateSerialization)
    case .accountChange(let change):
      handleAccountChange(change.changeType)
    case .fetchedRecordZoneChanges(let changes):
      applyFetchedChanges(changes)
    case .fetchedDatabaseChanges(let changes):
      applyDatabaseChanges(changes)
    case .sentRecordZoneChanges(let sent):
      handleSentChanges(sent)
    case .sentDatabaseChanges, .willFetchChanges, .didFetchChanges,
      .willFetchRecordZoneChanges, .didFetchRecordZoneChanges,
      .willSendChanges, .didSendChanges:
      break
    @unknown default:
      break
    }
  }

  public func nextRecordZoneChangeBatch(
    _ context: CKSyncEngine.SendChangesContext,
    syncEngine: CKSyncEngine
  ) async -> CKSyncEngine.RecordZoneChangeBatch? {
    let scope = context.options.scope
    let pending = engine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
    guard pending.isEmpty == false else { return nil }
    return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { [self] recordID in
      await makeRecord(for: recordID)
    }
  }

  // MARK: - Outbound

  /// Builds the `CKRecord` for a pending save, attaching the local file as a
  /// `CKAsset`. Returns `nil` (and drops the pending change) if the file is gone —
  /// e.g. the attachment was deleted before its upload ran — so the engine stops
  /// asking for it.
  private func makeRecord(for recordID: CKRecord.ID) -> CKRecord? {
    guard let fileURL = try? fileURL(forRecordName: recordID.recordName),
      FileManager.default.fileExists(atPath: fileURL.path)
    else {
      engine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
      return nil
    }
    let record = CKRecord(recordType: Self.recordType, recordID: recordID)
    record[Self.assetField] = CKAsset(fileURL: fileURL)
    return record
  }

  // MARK: - Inbound

  private func applyFetchedChanges(_ changes: CKSyncEngine.Event.FetchedRecordZoneChanges) {
    let fileManager = FileManager.default
    for modification in changes.modifications {
      let record = modification.record
      guard let asset = record[Self.assetField] as? CKAsset, let assetURL = asset.fileURL else { continue }
      guard let destination = try? fileURL(forRecordName: record.recordID.recordName) else { continue }
      do {
        if fileManager.fileExists(atPath: destination.path) {
          try fileManager.removeItem(at: destination)
        }
        // Copy synchronously: CKSyncEngine reclaims the asset's temp file as soon
        // as this delegate call returns.
        try fileManager.copyItem(at: assetURL, to: destination)
      } catch {
        log.error("import asset failed \(record.recordID.recordName, privacy: .public): \(error)")
      }
    }
    for deletion in changes.deletions {
      if let destination = try? fileURL(forRecordName: deletion.recordID.recordName) {
        try? fileManager.removeItem(at: destination)
      }
    }
  }

  private func applyDatabaseChanges(_ changes: CKSyncEngine.Event.FetchedDatabaseChanges) {
    let ourZone = zoneID()
    // Our zone vanished server-side (deleted / purged / encrypted-data reset) →
    // the local files no longer have a cloud counterpart.
    if changes.deletions.contains(where: { $0.zoneID == ourZone }) {
      wipeLocalMedia()
    }
  }

  private func handleSentChanges(_ sent: CKSyncEngine.Event.SentRecordZoneChanges) {
    for failure in sent.failedRecordSaves {
      let recordID = failure.record.recordID
      switch failure.error.code {
      case .serverRecordChanged:
        // Immutable record already on the server — treat as done.
        engine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
      case .zoneNotFound, .userDeletedZone:
        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneName: Self.zoneName))])
        engine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
      default:
        // Network / rate-limit / transient errors are retried by CKSyncEngine itself.
        log.error("record save failed \(recordID.recordName, privacy: .public): \(failure.error)")
      }
    }
  }

  private func handleAccountChange(_ changeType: CKSyncEngine.Event.AccountChange.ChangeType) {
    switch changeType {
    case .signOut, .switchAccounts:
      // Private journal media must not linger for a different iCloud user.
      wipeLocalMedia()
    case .signIn:
      break
    @unknown default:
      break
    }
  }

  // MARK: - Helpers

  private func zoneID() -> CKRecordZone.ID {
    CKRecordZone.ID(zoneName: Self.zoneName, ownerName: CKCurrentUserDefaultName)
  }

  private func recordID(for attachmentID: UUID) -> CKRecord.ID {
    CKRecord.ID(recordName: attachmentID.uuidString, zoneID: zoneID())
  }

  /// The local file for a record name (== attachment UUID == file name).
  private func fileURL(forRecordName recordName: String) throws -> URL {
    try JournalStore.mediaDirectory().appending(path: recordName, directoryHint: .notDirectory)
  }

  private func wipeLocalMedia() {
    if let directory = try? JournalStore.mediaDirectory() {
      try? FileManager.default.removeItem(at: directory)
    }
    clearState()
  }

  // MARK: - State persistence (App Group)

  private static func stateFileURL() -> URL? {
    guard
      let base = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: JournalStore.appGroupIdentifier
      )
    else {
      return nil
    }
    let directory = base.appending(path: "SyncState", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appending(path: stateFileName, directoryHint: .notDirectory)
  }

  private static func loadState() -> CKSyncEngine.State.Serialization? {
    guard let url = stateFileURL(), let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
  }

  private func saveState(_ serialization: CKSyncEngine.State.Serialization) {
    guard let url = Self.stateFileURL(), let data = try? JSONEncoder().encode(serialization) else { return }
    try? data.write(to: url, options: .atomic)
  }

  private func clearState() {
    if let url = Self.stateFileURL() {
      try? FileManager.default.removeItem(at: url)
    }
  }
}
