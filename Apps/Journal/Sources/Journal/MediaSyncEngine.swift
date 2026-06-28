import CloudKit
import Foundation
import JournalModel
import OSLog

/// Custom CloudKit sync for attachment **files** — the bytes that SwiftData's
/// `.automatic` mirroring deliberately does not carry (see `Attachment`).
///
/// It runs in the app process **alongside** the automatic mirroring, but in its
/// own private-database zone (`Media`), so the two never collide: `.automatic`
/// owns the `Card` / `Tag` / `Attachment` rows and any lightweight fallbacks,
/// while this
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
/// First-cut scope. It queues files at the app write boundary and lets the app
/// backfill known local attachments at launch for records created before media
/// sync was wired. Deferred (documented in the team notes): content-hash dedup,
/// download-on-demand UI, and a richer conflict / retry policy beyond what
/// CKSyncEngine already retries.
public actor MediaSyncEngine: CKSyncEngineDelegate {

  static let shared = MediaSyncEngine()

  /// Point-in-time status of the custom CKAsset sync engine.
  ///
  /// `CKSyncEngine` does not expose a user-facing progress percentage, so this
  /// captures the observable facts Journal can safely show: queued local work,
  /// whether the engine is actively fetching/sending, the last batch sizes, and
  /// the most recent error.
  public struct Snapshot: Sendable, Equatable {
    public var isFetchingChanges: Bool
    public var isSendingChanges: Bool
    public var pendingUploadCount: Int
    public var pendingDeleteCount: Int
    public var pendingDatabaseChangeCount: Int
    public var uploadedRecordCount: Int
    public var lastUploadedAt: Date?
    public var lastDownloadedAt: Date?
    public var lastDeletedAt: Date?
    public var lastErrorMessage: String?
    public var lastFetchedModificationCount: Int
    public var lastFetchedDeletionCount: Int
    public var lastSavedRecordCount: Int
    public var lastFailedRecordSaveCount: Int
    public var lastDeletedRecordCount: Int
    public var lastFailedRecordDeleteCount: Int

    public init(
      isFetchingChanges: Bool = false,
      isSendingChanges: Bool = false,
      pendingUploadCount: Int = 0,
      pendingDeleteCount: Int = 0,
      pendingDatabaseChangeCount: Int = 0,
      uploadedRecordCount: Int = 0,
      lastUploadedAt: Date? = nil,
      lastDownloadedAt: Date? = nil,
      lastDeletedAt: Date? = nil,
      lastErrorMessage: String? = nil,
      lastFetchedModificationCount: Int = 0,
      lastFetchedDeletionCount: Int = 0,
      lastSavedRecordCount: Int = 0,
      lastFailedRecordSaveCount: Int = 0,
      lastDeletedRecordCount: Int = 0,
      lastFailedRecordDeleteCount: Int = 0
    ) {
      self.isFetchingChanges = isFetchingChanges
      self.isSendingChanges = isSendingChanges
      self.pendingUploadCount = pendingUploadCount
      self.pendingDeleteCount = pendingDeleteCount
      self.pendingDatabaseChangeCount = pendingDatabaseChangeCount
      self.uploadedRecordCount = uploadedRecordCount
      self.lastUploadedAt = lastUploadedAt
      self.lastDownloadedAt = lastDownloadedAt
      self.lastDeletedAt = lastDeletedAt
      self.lastErrorMessage = lastErrorMessage
      self.lastFetchedModificationCount = lastFetchedModificationCount
      self.lastFetchedDeletionCount = lastFetchedDeletionCount
      self.lastSavedRecordCount = lastSavedRecordCount
      self.lastFailedRecordSaveCount = lastFailedRecordSaveCount
      self.lastDeletedRecordCount = lastDeletedRecordCount
      self.lastFailedRecordDeleteCount = lastFailedRecordDeleteCount
    }

    public var isWorking: Bool {
      isFetchingChanges
        || isSendingChanges
        || pendingUploadCount > 0
        || pendingDeleteCount > 0
        || pendingDatabaseChangeCount > 0
    }
  }

  private static let zoneName = "Media"
  private static let recordType = "MediaFile"
  private static let assetField = "asset"
  private static let stateFileName = "media-engine.json"
  private static let uploadedRecordNamesFileName = "media-uploaded-records.json"

  private let container: CKContainer
  private let savedState: CKSyncEngine.State.Serialization?
  private let log = Logger(subsystem: "app.muukii.journal", category: "MediaSync")
  private var uploadedRecordNames: Set<String>
  private var activity = Snapshot()

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
    self.uploadedRecordNames = Self.loadUploadedRecordNames()
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
    JournalMediaSyncStatusChange.post()
  }

  /// Returns the current media-sync status for diagnostics UI.
  public func snapshot() -> Snapshot {
    currentSnapshot()
  }

  /// Queues an attachment's file for upload. The host calls this right after
  /// `JournalStore` writes the file and saves the row.
  public func enqueueUpload(attachmentID: UUID) {
    enqueueUploads(attachmentIDs: [attachmentID])
  }

  /// Queues multiple freshly persisted attachment files for upload.
  ///
  /// The caller passes only UUIDs so SwiftData models never cross this actor
  /// boundary. Existing server-confirmed records are skipped, which lets launch
  /// backfill and save-time enqueue share the same path without re-sending files
  /// that are already known to have a CloudKit counterpart.
  public func enqueueUploads(attachmentIDs: [UUID]) {
    enqueueSaves(recordNames: attachmentIDs.map(\.uuidString))
  }

  /// Queues an attachment's remote file for deletion. The local file is removed by
  /// `JournalStore.deleteAttachment` / `reconcileOrphanFiles`; this removes the
  /// CloudKit copy.
  public func enqueueDelete(attachmentID: UUID) {
    let recordName = attachmentID.uuidString
    let recordID = recordID(forRecordName: recordName)
    engine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
    removeUploadedRecordName(recordName)
    addPendingRecordZoneChange(.deleteRecord(recordID))
  }

  // MARK: - CKSyncEngineDelegate

  public func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
    defer { JournalMediaSyncStatusChange.post() }

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
    case .willFetchChanges, .willFetchRecordZoneChanges:
      activity.isFetchingChanges = true
    case .didFetchChanges, .didFetchRecordZoneChanges:
      activity.isFetchingChanges = false
    case .willSendChanges:
      activity.isSendingChanges = true
    case .didSendChanges, .sentDatabaseChanges:
      activity.isSendingChanges = false
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
    var importedCount = 0
    var deletedCount = 0
    var hadFailure = false
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
        markUploaded(recordNames: [record.recordID.recordName])
        JournalMediaFileChange.post(attachmentID: UUID(uuidString: record.recordID.recordName))
        importedCount += 1
      } catch {
        hadFailure = true
        activity.lastErrorMessage = error.localizedDescription
        log.error("import asset failed \(record.recordID.recordName, privacy: .public): \(error)")
      }
    }
    for deletion in changes.deletions {
      if let destination = try? fileURL(forRecordName: deletion.recordID.recordName) {
        try? fileManager.removeItem(at: destination)
        removeUploadedRecordName(deletion.recordID.recordName)
        JournalMediaFileChange.post(attachmentID: UUID(uuidString: deletion.recordID.recordName))
        deletedCount += 1
      }
    }
    activity.lastFetchedModificationCount = importedCount
    activity.lastFetchedDeletionCount = deletedCount
    if importedCount > 0 {
      activity.lastDownloadedAt = Date()
      if hadFailure == false {
        activity.lastErrorMessage = nil
      }
    }
    if deletedCount > 0 {
      activity.lastDeletedAt = Date()
      if hadFailure == false {
        activity.lastErrorMessage = nil
      }
    }
  }

  private func applyDatabaseChanges(_ changes: CKSyncEngine.Event.FetchedDatabaseChanges) {
    let ourZone = zoneID()
    // Our zone vanished server-side (deleted / purged / encrypted-data reset) →
    // the local files no longer have a cloud counterpart.
    if changes.deletions.contains(where: { $0.zoneID == ourZone }) {
      activity.lastErrorMessage = "Media sync zone was removed in iCloud."
      wipeLocalMedia()
    }
  }

  private func handleSentChanges(_ sent: CKSyncEngine.Event.SentRecordZoneChanges) {
    activity.lastSavedRecordCount = sent.savedRecords.count
    activity.lastFailedRecordSaveCount = sent.failedRecordSaves.count
    activity.lastDeletedRecordCount = sent.deletedRecordIDs.count
    activity.lastFailedRecordDeleteCount = sent.failedRecordDeletes.count

    markUploaded(recordNames: sent.savedRecords.map { $0.recordID.recordName })

    for recordID in sent.deletedRecordIDs {
      removeUploadedRecordName(recordID.recordName)
    }

    for failure in sent.failedRecordSaves {
      let recordID = failure.record.recordID
      switch failure.error.code {
      case .serverRecordChanged:
        // Immutable record already on the server — treat as done.
        engine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
        markUploaded(recordNames: [recordID.recordName])
      case .zoneNotFound, .userDeletedZone:
        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneName: Self.zoneName))])
        engine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
      default:
        // Network / rate-limit / transient errors are retried by CKSyncEngine itself.
        activity.lastErrorMessage = failure.error.localizedDescription
        log.error("record save failed \(recordID.recordName, privacy: .public): \(failure.error)")
      }
    }

    for (recordID, error) in sent.failedRecordDeletes {
      switch error.code {
      case .unknownItem, .zoneNotFound, .userDeletedZone:
        engine.state.remove(pendingRecordZoneChanges: [.deleteRecord(recordID)])
        removeUploadedRecordName(recordID.recordName)
      default:
        activity.lastErrorMessage = error.localizedDescription
        log.error("record delete failed \(recordID.recordName, privacy: .public): \(error)")
      }
    }

    let hasFailure = sent.failedRecordSaves.isEmpty == false || sent.failedRecordDeletes.isEmpty == false
    if sent.savedRecords.isEmpty == false {
      activity.lastUploadedAt = Date()
      if hasFailure == false {
        activity.lastErrorMessage = nil
      }
    }
    if sent.deletedRecordIDs.isEmpty == false {
      activity.lastDeletedAt = Date()
      if hasFailure == false {
        activity.lastErrorMessage = nil
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

  private func currentSnapshot() -> Snapshot {
    var snapshot = activity
    snapshot.pendingUploadCount = 0
    snapshot.pendingDeleteCount = 0
    snapshot.pendingDatabaseChangeCount = 0
    snapshot.uploadedRecordCount = 0
    for change in engine.state.pendingRecordZoneChanges {
      switch change {
      case .saveRecord:
        snapshot.pendingUploadCount += 1
      case .deleteRecord:
        snapshot.pendingDeleteCount += 1
      @unknown default:
        break
      }
    }
    snapshot.pendingDatabaseChangeCount = engine.state.pendingDatabaseChanges.count
    snapshot.uploadedRecordCount = uploadedRecordNames.count
    return snapshot
  }

  private func recordID(forRecordName recordName: String) -> CKRecord.ID {
    CKRecord.ID(recordName: recordName, zoneID: zoneID())
  }

  private func enqueueSaves(recordNames: [String]) {
    let changes = recordNames
      .filter { uploadedRecordNames.contains($0) == false }
      .map { CKSyncEngine.PendingRecordZoneChange.saveRecord(recordID(forRecordName: $0)) }

    for change in Set(changes) {
      addPendingRecordZoneChange(change)
    }
  }

  private func addPendingRecordZoneChange(_ change: CKSyncEngine.PendingRecordZoneChange) {
    guard engine.state.pendingRecordZoneChanges.contains(change) == false else {
      return
    }
    engine.state.add(pendingRecordZoneChanges: [change])
    JournalMediaSyncStatusChange.post()
  }

  private func markUploaded(recordNames: [String]) {
    let oldCount = uploadedRecordNames.count
    uploadedRecordNames.formUnion(recordNames)
    if uploadedRecordNames.count != oldCount {
      saveUploadedRecordNames()
    }
  }

  private func removeUploadedRecordName(_ recordName: String) {
    guard uploadedRecordNames.remove(recordName) != nil else { return }
    saveUploadedRecordNames()
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
    JournalMediaFileChange.post(attachmentID: nil)
  }

  // MARK: - State persistence (App Group)

  private static func syncStateDirectory() -> URL? {
    guard
      let base = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: JournalStore.appGroupIdentifier
      )
    else {
      return nil
    }
    let directory = base.appending(path: "SyncState", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private static func stateFileURL() -> URL? {
    guard let directory = syncStateDirectory() else { return nil }
    return directory.appending(path: stateFileName, directoryHint: .notDirectory)
  }

  private static func uploadedRecordNamesFileURL() -> URL? {
    guard let directory = syncStateDirectory() else { return nil }
    return directory.appending(path: uploadedRecordNamesFileName, directoryHint: .notDirectory)
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
    if let url = Self.uploadedRecordNamesFileURL() {
      try? FileManager.default.removeItem(at: url)
    }
    uploadedRecordNames.removeAll()
  }

  private static func loadUploadedRecordNames() -> Set<String> {
    guard
      let url = uploadedRecordNamesFileURL(),
      let data = try? Data(contentsOf: url),
      let names = try? JSONDecoder().decode([String].self, from: data)
    else {
      return []
    }
    return Set(names)
  }

  private func saveUploadedRecordNames() {
    guard
      let url = Self.uploadedRecordNamesFileURL(),
      let data = try? JSONEncoder().encode(uploadedRecordNames.sorted())
    else {
      return
    }
    try? data.write(to: url, options: .atomic)
  }
}
