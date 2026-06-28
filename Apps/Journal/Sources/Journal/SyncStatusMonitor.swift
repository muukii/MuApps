import CloudKit
import CoreData
import Foundation
import JournalModel
import Observation
import SwiftData

/// App-wide observer of CloudKit sync health, surfaced in Settings.
///
/// It reduces three signals into one coarse, honest status:
/// 1. **Account** — `CKContainer.accountStatus()` (refreshed on `.CKAccountChanged`).
///    Without an available account, sync simply never runs, so this gates everything.
/// 2. **Row sync** — SwiftData's `.automatic` mirroring, observed via
///    `NSPersistentCloudKitContainer.eventChangedNotification` (setup / import /
///    export events). `endDate == nil` means that event is in progress.
/// 3. **Media sync** — Journal's custom `MediaSyncEngine`, which transports
///    attachment files as CKAssets outside the SwiftData store.
///
/// Deliberately coarse: a finished import/export event does **not** prove the whole
/// store reached the server (events fire per-batch, in bursts, with no progress
/// signal), so this never claims "fully synced" or shows a percentage — only a
/// phase and best-effort timestamps.
///
/// App-lifetime singleton so the status accrues across Settings opens and is ready
/// instantly. `@Observable`, so views that read `summary` in their `body` track it.
@MainActor
@Observable
final class SyncStatusMonitor {

  static let shared = SyncStatusMonitor()

  /// The single coarse state Settings renders. Pure state — the SF Symbol, color,
  /// and copy are chosen in the view.
  enum Summary: Equatable {
    case checking
    case accountUnavailable(reason: String)
    case syncing(label: String)
    case failed(message: String)
    case idle(lastSyncedAt: Date?)
  }

  /// User-facing account availability details for the diagnostics screen.
  struct AccountDetail: Equatable {
    var status: String
    var isAvailable: Bool

    static let checking = AccountDetail(
      status: "Checking iCloud account…",
      isAvailable: false
    )
  }

  /// Current state of SwiftData/Core Data's CloudKit mirroring events.
  struct RowSyncDetail: Equatable {
    var setupInProgress = false
    var importInProgress = false
    var exportInProgress = false
    var lastSyncedAt: Date?
    var lastErrorMessage: String?
  }

  /// The `Sendable` slice of an `NSPersistentCloudKitContainer.Event` needed by UI.
  ///
  /// The real Core Data event and the notification that carries it are not
  /// `Sendable`; this snapshot is extracted synchronously on the posting thread
  /// and then applied on the main actor.
  struct MirroringEvent: Identifiable, Equatable, Sendable {
    var id: UUID
    var storeIdentifier: String
    var type: NSPersistentCloudKitContainer.EventType
    var startDate: Date
    var endDate: Date?
    var succeeded: Bool
    var errorMessage: String?

    var isActive: Bool {
      endDate == nil
    }
  }

  private(set) var summary: Summary = .checking
  private(set) var accountDetail: AccountDetail = .checking
  private(set) var rowSyncDetail = RowSyncDetail()
  private(set) var mediaSyncSnapshot = MediaSyncEngine.Snapshot()
  private(set) var localMediaAvailability = JournalStore.LocalMediaAvailability()
  private(set) var localMediaErrorMessage: String?
  private(set) var recentMirroringEvents: [MirroringEvent] = []

  // MARK: - Inputs

  fileprivate enum Account: Equatable {
    case unknown
    case available
    case unavailable(String)
  }

  private var account: Account = .unknown
  private var setupInProgress = false
  private var importInProgress = false
  private var exportInProgress = false
  private var lastError: String?
  private var lastSyncedAt: Date?

  private let container: CKContainer
  private var hasStarted = false
  private static let recentEventLimit = 12

  private init(containerIdentifier: String = "iCloud.app.muukii.journal") {
    self.container = CKContainer(identifier: containerIdentifier)
  }

  /// Begins observing. Call once at launch; repeat calls are ignored.
  func start() {
    guard hasStarted == false else { return }
    hasStarted = true

    observeMirroringEvents()
    observeAccountChanges()
    observeMediaSyncChanges()
    Task { await refreshAccountStatus() }
    Task { await refreshMediaSnapshot() }
  }

  /// Refreshes diagnostics that require current local store state.
  ///
  /// Settings calls this on appear and from its refresh button. Account and row
  /// mirroring events continue to update independently through notifications.
  func refreshDetails(in context: ModelContext) async {
    do {
      localMediaAvailability = try JournalStore.localMediaAvailability(in: context)
      localMediaErrorMessage = nil
    } catch {
      localMediaErrorMessage = error.localizedDescription
    }
    await refreshMediaSnapshot()
  }

  // MARK: - Data sync (NSPersistentCloudKitContainer)

  private func observeMirroringEvents() {
    // The notification posts on Core Data's background queue, and neither
    // `Notification` nor the event is `Sendable`. Extract a `Sendable` snapshot
    // inside the block (the block captures only the `Sendable` continuation), then
    // apply it on the main actor by iterating the stream from a `@MainActor` Task.
    let (stream, continuation) = AsyncStream<MirroringEvent>.makeStream()
    NotificationCenter.default.addObserver(
      forName: NSPersistentCloudKitContainer.eventChangedNotification,
      object: nil,
      queue: nil
    ) { notification in
      // Read the non-`Sendable` event synchronously and yield only the `Sendable`
      // snapshot — `notification` itself never leaves this block.
      guard
        let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
          as? NSPersistentCloudKitContainer.Event
      else {
        return
      }
      continuation.yield(
        MirroringEvent(
          id: event.identifier,
          storeIdentifier: event.storeIdentifier,
          type: event.type,
          startDate: event.startDate,
          endDate: event.endDate,
          succeeded: event.succeeded,
          errorMessage: event.error?.localizedDescription
        )
      )
    }
    Task { [weak self] in
      for await event in stream {
        self?.apply(event)
      }
    }
  }

  private func apply(_ event: MirroringEvent) {
    recentMirroringEvents.removeAll { $0.id == event.id }
    recentMirroringEvents.insert(event, at: 0)
    if recentMirroringEvents.count > Self.recentEventLimit {
      recentMirroringEvents.removeLast(recentMirroringEvents.count - Self.recentEventLimit)
    }

    let isActive = event.endDate == nil
    switch event.type {
    case .setup: setupInProgress = isActive
    case .`import`: importInProgress = isActive
    case .export: exportInProgress = isActive
    @unknown default: break
    }

    if isActive == false {
      if event.succeeded {
        lastError = nil
        // Setup completing isn't a data round-trip; only import/export advance the
        // "last synced" mark.
        if event.type != .setup {
          lastSyncedAt = event.endDate ?? Date()
        }
      } else if let message = event.errorMessage {
        lastError = message
      }
    }
    recompute()
  }

  private var isSyncingData: Bool {
    setupInProgress || importInProgress || exportInProgress
  }

  private var isSyncingMedia: Bool {
    mediaSyncSnapshot.isWorking
  }

  /// Coarse phase label, most-informative first.
  private var syncingLabel: String {
    if setupInProgress { return "Setting up iCloud…" }
    if exportInProgress { return "Uploading to iCloud…" }
    if importInProgress { return "Downloading from iCloud…" }
    if mediaSyncSnapshot.pendingUploadCount > 0 { return "Uploading media files…" }
    if mediaSyncSnapshot.pendingDeleteCount > 0 { return "Deleting media files…" }
    if mediaSyncSnapshot.isSendingChanges { return "Sending media changes…" }
    if mediaSyncSnapshot.isFetchingChanges { return "Checking media files…" }
    return "Syncing media files…"
  }

  // MARK: - Account

  private func observeAccountChanges() {
    let (stream, continuation) = AsyncStream<Void>.makeStream()
    NotificationCenter.default.addObserver(
      forName: .CKAccountChanged,
      object: nil,
      queue: nil
    ) { _ in
      continuation.yield(())
    }
    Task { [weak self] in
      for await _ in stream {
        await self?.refreshAccountStatus()
      }
    }
  }

  private func observeMediaSyncChanges() {
    let (stream, continuation) = AsyncStream<Void>.makeStream()
    NotificationCenter.default.addObserver(
      forName: JournalMediaSyncStatusChange.notificationName,
      object: nil,
      queue: nil
    ) { _ in
      continuation.yield(())
    }
    Task { [weak self] in
      for await _ in stream {
        await self?.refreshMediaSnapshot()
      }
    }
  }

  private func refreshAccountStatus() async {
    let status = (try? await container.accountStatus()) ?? .couldNotDetermine
    switch status {
    case .available:
      account = .available
    case .noAccount:
      account = .unavailable("Not signed in to iCloud")
    case .restricted:
      account = .unavailable("iCloud is restricted on this device")
    case .temporarilyUnavailable:
      account = .unavailable("iCloud is temporarily unavailable")
    case .couldNotDetermine:
      account = .unknown
    @unknown default:
      account = .unknown
    }
    recompute()
  }

  private func refreshMediaSnapshot() async {
    mediaSyncSnapshot = await MediaSyncEngine.shared.snapshot()
    recompute()
  }

  // MARK: - Reduction

  private func recompute() {
    accountDetail = AccountDetail(account: account)
    rowSyncDetail = RowSyncDetail(
      setupInProgress: setupInProgress,
      importInProgress: importInProgress,
      exportInProgress: exportInProgress,
      lastSyncedAt: lastSyncedAt,
      lastErrorMessage: lastError
    )

    switch account {
    case .unavailable(let reason):
      summary = .accountUnavailable(reason: reason)
    case .unknown:
      summary = (isSyncingData || isSyncingMedia) ? .syncing(label: syncingLabel) : .checking
    case .available:
      if let message = lastError ?? mediaSyncSnapshot.lastErrorMessage {
        summary = .failed(message: message)
      } else if isSyncingData || isSyncingMedia {
        summary = .syncing(label: syncingLabel)
      } else {
        summary = .idle(lastSyncedAt: combinedLastSyncedAt)
      }
    }
  }

  private var combinedLastSyncedAt: Date? {
    let dates = [
      lastSyncedAt,
      mediaSyncSnapshot.lastUploadedAt,
      mediaSyncSnapshot.lastDownloadedAt,
      mediaSyncSnapshot.lastDeletedAt,
    ].compactMap { $0 }
    return dates.min()
  }
}

// MARK: - Detail construction

private extension SyncStatusMonitor.AccountDetail {

  init(account: SyncStatusMonitor.Account) {
    switch account {
    case .unknown:
      self = .checking
    case .available:
      self.init(status: "Available", isAvailable: true)
    case .unavailable(let reason):
      self.init(status: reason, isAvailable: false)
    }
  }
}
