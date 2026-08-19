import Foundation
import JournalVault
import OSLog
import SharedWithYou

/// App-runtime boundary needed to drain ready local Shared with You notices.
///
/// A protocol is useful here because the coordinator has two real clients: the
/// process-lifetime `JournalVaultRuntime` and deterministic Tinycurve tests.
/// The vault module still owns persistence and never imports Messages UI.
@MainActor
protocol SharedWithYouNoticeRuntime: AnyObject {

  /// Every locally known vault that may contain a durable notice intent.
  var sharedWithYouNoticeVaultIDs: [VaultID] { get }

  /// Current catalog snapshot used to obtain the saved collaboration share URL.
  func sharedWithYouNoticeDescriptor(for vaultID: VaultID) -> VaultDescriptor?

  /// Process-stable local state-machine owner for one vault.
  func sharedWithYouNoticeStore(for vaultID: VaultID) throws -> VaultSharedWithYouNoticeStore

  /// Ack-only stream for rows that actually changed from waiting to ready.
  func readySharedWithYouNoticeVaults() -> AsyncStream<VaultID>

  /// Records an aggregate diagnostic after invoking the system post API.
  func noteSharedWithYouNoticePosted(for vaultID: VaultID, at date: Date)
}

extension JournalVaultRuntime: SharedWithYouNoticeRuntime {}

/// Resolved system collaboration highlight whose only exposed operation is to
/// post a root-edit or reply-comment notice.
///
/// The wrapper keeps `SWCollaborationHighlight` and `SWHighlightCenter` inside
/// the app target while making the coordinator's client inexpensive to fake.
@MainActor
struct SharedWithYouNoticeHighlight {

  private let post: @MainActor (VaultSharedWithYouNoticeChange) -> Void

  init(post: @escaping @MainActor (VaultSharedWithYouNoticeChange) -> Void) {
    self.post = post
  }

  /// Posts the supplied Activity topology projection through the system API.
  func postNotice(change: VaultSharedWithYouNoticeChange) {
    post(change)
  }
}

/// Injectable adapter over Shared with You's collaboration-highlight APIs.
@MainActor
protocol SharedWithYouHighlightClient: AnyObject {

  /// Whether this device can use system Messages collaboration notices.
  var isSystemCollaborationSupportAvailable: Bool { get }

  /// Resolves the highlight associated with a saved CloudKit share URL.
  ///
  /// Returning `nil` is terminal for a particular local notice: the share may
  /// have been sent through a non-Messages surface, so retrying cannot create a
  /// collaboration highlight retroactively.
  func getCollaborationHighlight(
    for shareURL: URL
  ) async throws -> SharedWithYouNoticeHighlight?
}

/// Production adapter for `SWHighlightCenter`.
@MainActor
final class SystemSharedWithYouHighlightClient: SharedWithYouHighlightClient {

  private let highlightCenter: SWHighlightCenter

  init(highlightCenter: SWHighlightCenter = SWHighlightCenter()) {
    self.highlightCenter = highlightCenter
  }

  var isSystemCollaborationSupportAvailable: Bool {
    SWHighlightCenter.isSystemCollaborationSupportAvailable
  }

  func getCollaborationHighlight(
    for shareURL: URL
  ) async throws -> SharedWithYouNoticeHighlight? {
    // The callback supplies an SDK object with no Sendable conformance. Carry
    // only its copied identifier across the continuation, then resolve the
    // highlight again on this MainActor-isolated adapter before retaining it.
    let collaborationIdentifier: String? = try await withCheckedThrowingContinuation {
      continuation in
      highlightCenter.getCollaborationHighlight(for: shareURL) { highlight, error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume(returning: highlight?.collaborationIdentifier)
        }
      }
    }

    guard let collaborationIdentifier else { return nil }
    let collaborationHighlight = try highlightCenter.collaborationHighlight(
      forIdentifier: collaborationIdentifier
    )
    return SharedWithYouNoticeHighlight { [highlightCenter, collaborationHighlight] change in
      let trigger: SWHighlightChangeEventTrigger
      switch change {
      case .edit:
        trigger = .edit
      case .comment:
        trigger = .comment
      }
      let event = SWHighlightChangeEvent(highlight: collaborationHighlight, trigger: trigger)
      highlightCenter.postNotice(for: event)
    }
  }
}

/// App-lifetime worker that drains ready Shared with You notice intents.
///
/// The worker listens for acknowledgement events, then drains every local vault
/// after the app first has an active scene and on later app-level foreground
/// transitions. Those paths recover rows created by App Intents or the Share
/// extension, which cannot reach this process's in-memory event stream. It
/// deliberately never creates intent rows and never asks CloudKit to retry an
/// Activity; those are separate persistence and transport responsibilities.
@MainActor
final class SharedWithYouNoticeDeliveryCoordinator {

  /// Maximum number of persisted transient lookup failures before terminally
  /// skipping one local intent.
  static let maximumLookupAttempts = 3

  /// Upper bound for one vault drain so a burst cannot monopolize the main app
  /// lifecycle transition.
  static let drainBatchSize = 100

  /// Upper bound for terminal local-only rows removed after one drain.
  static let terminalPurgeLimit = 100

  private let runtime: any SharedWithYouNoticeRuntime
  private let highlightClient: any SharedWithYouHighlightClient
  private let now: @MainActor () -> Date

  /// Cooperative scheduling point after an empty ready snapshot.
  ///
  /// A registry event can become ready while this coordinator owns a vault
  /// drain. Yielding lets the event task coalesce that request before the
  /// owner relinquishes the vault. Tests replace this with a deterministic
  /// same-vault event at the otherwise narrow completion boundary.
  private let yieldAfterEmptyReadySnapshot: @MainActor () async -> Void
  private let logger = Logger(subsystem: "app.muukii.journal", category: "SharedWithYouNotice")

  private var readyNoticeTask: Task<Void, Never>?
  private var drainingVaultIDs = Set<VaultID>()
  private var pendingRedrainVaultIDs = Set<VaultID>()
  private var activeSceneIDs = Set<UUID>()
  private var hasStarted = false
  private var needsInitialRecovery = true

  /// Creates the process-scoped coordinator.
  ///
  /// - Parameters:
  ///   - runtime: Catalog and vault-local persistence owner.
  ///   - highlightClient: System adapter, injectable so tests never access a
  ///     real Messages or Shared with You service.
  ///   - now: Clock seam for durable retry and at-most-once assertions.
  ///   - yieldAfterEmptyReadySnapshot: Scheduling seam that lets ready events
  ///     coalesce before a vault drain releases its single-owner claim.
  init(
    runtime: any SharedWithYouNoticeRuntime,
    highlightClient: any SharedWithYouHighlightClient = SystemSharedWithYouHighlightClient(),
    now: @escaping @MainActor () -> Date = Date.init,
    yieldAfterEmptyReadySnapshot: @escaping @MainActor () async -> Void = {
      await Task.yield()
    }
  ) {
    self.runtime = runtime
    self.highlightClient = highlightClient
    self.now = now
    self.yieldAfterEmptyReadySnapshot = yieldAfterEmptyReadySnapshot
  }

  deinit {
    readyNoticeTask?.cancel()
  }

  /// Starts ack observation once and recovers local vaults after an active
  /// scene is known.
  ///
  /// The caller supplies its initial scene state so an already-active root is
  /// registered before the startup drain. A later `.active` callback for that
  /// same scene is then a no-op, while a real all-inactive-to-active transition
  /// remains eligible to recover notices.
  func start(sceneID: UUID, isSceneActive: Bool) async {
    let wasAppInactive = activeSceneIDs.isEmpty
    if isSceneActive {
      activeSceneIDs.insert(sceneID)
    }

    if hasStarted == false {
      hasStarted = true

      if readyNoticeTask == nil {
        let stream = runtime.readySharedWithYouNoticeVaults()
        readyNoticeTask = Task { @MainActor [weak self] in
          for await vaultID in stream {
            guard Task.isCancelled == false else { return }
            await self?.drain(vaultID: vaultID)
          }
        }
      }
    }

    await drainAfterSceneActivationIfNeeded(wasAppInactive: wasAppInactive)
  }

  /// Records one scene becoming active and recovers notices on an actual
  /// app-level background-to-foreground transition.
  ///
  /// Multiple macOS windows can become active together. Only the transition
  /// from no active scenes to one active scene triggers a recovery pass, so a
  /// single transient lookup failure is not consumed once per window.
  func sceneDidBecomeActive(_ sceneID: UUID) async {
    let wasAppInactive = activeSceneIDs.isEmpty
    guard activeSceneIDs.insert(sceneID).inserted, hasStarted else {
      return
    }

    await drainAfterSceneActivationIfNeeded(wasAppInactive: wasAppInactive)
  }

  /// Removes a scene from app-level activation tracking.
  ///
  /// The next active scene triggers a recovery only after every current scene
  /// has become inactive, which is the app-level activation boundary rather
  /// than a per-window callback.
  func sceneDidBecomeInactive(_ sceneID: UUID) {
    activeSceneIDs.remove(sceneID)
  }

  /// Performs exactly one initial recovery after the app first has an active
  /// scene, then one recovery for each later app-level foreground transition.
  private func drainAfterSceneActivationIfNeeded(wasAppInactive: Bool) async {
    guard activeSceneIDs.isEmpty == false else { return }

    if needsInitialRecovery {
      needsInitialRecovery = false
      await drainAllVaults()
    } else if wasAppInactive {
      await drainAllVaults()
    }
  }

  /// Drains each catalog-known vault once for the current lifecycle boundary.
  func drainAllVaults() async {
    let vaultIDs = runtime.sharedWithYouNoticeVaultIDs
    for vaultID in vaultIDs {
      await drain(vaultID: vaultID)
    }
  }

  /// Drains one vault's current ready snapshot without retrying a transient
  /// failure in the same call.
  func drain(vaultID: VaultID) async {
    guard drainingVaultIDs.insert(vaultID).inserted else {
      // An acknowledgement can arrive after this drain's final empty snapshot.
      // Remember it so the owner re-scans before releasing its single-owner
      // claim instead of stranding the new ready row until a later lifecycle
      // transition.
      pendingRedrainVaultIDs.insert(vaultID)
      return
    }
    defer {
      drainingVaultIDs.remove(vaultID)
      pendingRedrainVaultIDs.remove(vaultID)
    }

    let store: VaultSharedWithYouNoticeStore
    do {
      store = try runtime.sharedWithYouNoticeStore(for: vaultID)
    } catch {
      logger.error("open notice store failed: \(error.localizedDescription, privacy: .public)")
      return
    }

    var processedActivityIDs = Set<UUID>()
    while true {
      let candidates: [VaultSharedWithYouNoticeCandidate]
      do {
        candidates = try await store.readyCandidates(
          limit: Self.drainBatchSize,
          excluding: processedActivityIDs,
          now: now()
        )
      } catch {
        logger.error("read ready notices failed: \(error.localizedDescription, privacy: .public)")
        return
      }

      guard candidates.isEmpty == false else {
        // Give a concurrently received registry event a chance to mark this
        // vault before the terminal cleanup below suspends the current drain.
        await yieldAfterEmptyReadySnapshot()
        if pendingRedrainVaultIDs.remove(vaultID) != nil {
          continue
        }

        do {
          _ = try await store.purgeTerminalNotices(limit: Self.terminalPurgeLimit)
        } catch {
          logger.error(
            "purge terminal notices failed: \(error.localizedDescription, privacy: .public)"
          )
        }

        // `purgeTerminalNotices` crosses the actor boundary. Consume an event
        // that arrived during it before releasing the per-vault claim.
        await yieldAfterEmptyReadySnapshot()
        if pendingRedrainVaultIDs.remove(vaultID) != nil {
          continue
        }
        break
      }

      for candidate in candidates {
        // A transient lookup leaves the row ready. Remember it for this one
        // drain so later batches advance instead of consuming the retry budget
        // in a tight lifecycle loop.
        guard processedActivityIDs.insert(candidate.activityID).inserted else {
          continue
        }
        await deliver(candidate, in: vaultID, using: store)
      }

      await Task.yield()
    }
  }

  private func deliver(
    _ candidate: VaultSharedWithYouNoticeCandidate,
    in vaultID: VaultID,
    using store: VaultSharedWithYouNoticeStore
  ) async {
    guard highlightClient.isSystemCollaborationSupportAvailable else {
      await markSkipped(candidate.activityID, using: store)
      return
    }

    guard let shareURL = runtime.sharedWithYouNoticeDescriptor(for: vaultID)?.shareURL else {
      await markSkipped(candidate.activityID, using: store)
      return
    }

    let highlight: SharedWithYouNoticeHighlight?
    do {
      highlight = try await highlightClient.getCollaborationHighlight(for: shareURL)
    } catch {
      do {
        _ = try await store.recordTransientLookupFailure(
          activityID: candidate.activityID,
          maximumAttempts: Self.maximumLookupAttempts,
          at: now()
        )
      } catch {
        logger.error(
          "record highlight retry failed: \(error.localizedDescription, privacy: .public)")
      }
      return
    }

    guard let highlight else {
      await markSkipped(candidate.activityID, using: store)
      return
    }

    let attemptedAt = now()
    do {
      // Retention or a remote deletion can remove this row after the ready
      // snapshot. `false` makes that race safe: do not post a stale notice.
      guard try await store.markAttempted(activityID: candidate.activityID, at: attemptedAt) else {
        return
      }
    } catch {
      logger.error(
        "persist attempted notice failed: \(error.localizedDescription, privacy: .public)")
      return
    }

    highlight.postNotice(change: candidate.change)
    runtime.noteSharedWithYouNoticePosted(for: vaultID, at: attemptedAt)
  }

  private func markSkipped(
    _ activityID: UUID,
    using store: VaultSharedWithYouNoticeStore
  ) async {
    do {
      _ = try await store.markSkipped(activityID: activityID, at: now())
    } catch {
      logger.error("persist skipped notice failed: \(error.localizedDescription, privacy: .public)")
    }
  }
}
