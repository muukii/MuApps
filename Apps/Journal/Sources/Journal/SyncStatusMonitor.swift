import CloudKit
import CoreData
import Foundation
import Observation

/// App-wide observer of CloudKit sync health, surfaced in Settings.
///
/// It reduces two signals into one coarse, honest status:
/// 1. **Account** — `CKContainer.accountStatus()` (refreshed on `.CKAccountChanged`).
///    Without an available account, sync simply never runs, so this gates everything.
/// 2. **Data sync** — SwiftData's `.automatic` mirroring, observed via
///    `NSPersistentCloudKitContainer.eventChangedNotification` (setup / import /
///    export events). `endDate == nil` means that event is in progress.
///
/// Deliberately coarse: a finished import/export event does **not** prove the whole
/// store reached the server (events fire per-batch, in bursts, with no progress
/// signal), so this never claims "fully synced" or shows a percentage — only a
/// phase and a best-effort `lastSyncedAt`.
///
/// App-lifetime singleton so the status accrues across Settings opens and is ready
/// instantly. `@Observable`, so views that read `summary` in their `body` track it.
///
/// TODO: fold in `MediaSyncEngine` (the CKAsset file sync). It already runs its own
/// CKSyncEngine; expose an `AsyncStream<EngineSyncState>` from it and OR its
/// activity/error into `summary` (severity: error > syncing > idle), taking the
/// older of the two `lastSyncedAt`. Deferred until media upload has a call site.
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

  private(set) var summary: Summary = .checking

  // MARK: - Inputs

  private enum Account: Equatable {
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

  private init(containerIdentifier: String = "iCloud.app.muukii.journal") {
    self.container = CKContainer(identifier: containerIdentifier)
  }

  /// Begins observing. Call once at launch; repeat calls are ignored.
  func start() {
    guard hasStarted == false else { return }
    hasStarted = true

    observeMirroringEvents()
    observeAccountChanges()
    Task { await refreshAccountStatus() }
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
          type: event.type,
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

  /// Coarse phase label, most-informative first.
  private var syncingLabel: String {
    if setupInProgress { return "Setting up iCloud…" }
    if exportInProgress { return "Uploading to iCloud…" }
    return "Downloading from iCloud…"
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

  // MARK: - Reduction

  private func recompute() {
    switch account {
    case .unavailable(let reason):
      summary = .accountUnavailable(reason: reason)
    case .unknown:
      summary = isSyncingData ? .syncing(label: syncingLabel) : .checking
    case .available:
      if let lastError {
        summary = .failed(message: lastError)
      } else if isSyncingData {
        summary = .syncing(label: syncingLabel)
      } else {
        summary = .idle(lastSyncedAt: lastSyncedAt)
      }
    }
  }
}

// MARK: - Sendable snapshot

/// The `Sendable` slice of an `NSPersistentCloudKitContainer.Event` needed to drive
/// the indicator — extracted on the posting thread so nothing non-`Sendable`
/// crosses to the main actor.
private struct MirroringEvent: Sendable {
  let type: NSPersistentCloudKitContainer.EventType
  let endDate: Date?
  let succeeded: Bool
  let errorMessage: String?
}
