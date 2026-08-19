import CloudKit
import Foundation
import JournalVault
import Observation

/// Coordinates Tinycurve's process-lifetime observation of system CloudKit
/// sharing UI.
///
/// The observer is deliberately owned by ``TinycurveApp`` rather than a view:
/// a sharing service can finish after its presenting SwiftUI view has changed.
/// This type funnels successful system save and stop callbacks through
/// ``JournalVaultRuntime`` while separately tracking an initial owner-invite
/// session for the contextual notification primer.
@MainActor
@Observable
final class VaultSystemSharingCoordinator {

  @ObservationIgnored private let vaultRuntime: JournalVaultRuntime
  @ObservationIgnored private let systemNotificationAuthorization: SystemNotificationAuthorization
  @ObservationIgnored private let observer: CKSystemSharingUIObserver

  /// Only the currently presented initial owner-invite sheet can earn a
  /// notification primer. Existing collaboration controls still refresh their
  /// UI through the system observer, but never create this session.
  @ObservationIgnored private var ownerSharePresentation: VaultOwnerSharePresentationLifecycle?

  /// A catalog refresh is in flight for this session. Keeping the session live
  /// until that refresh returns lets a late cancellation or stop callback win
  /// the race and suppress the primer.
  @ObservationIgnored private var pendingPrimerSessionID: UUID?

  /// Creates the app-scoped bridge for the Tinycurve CloudKit container.
  ///
  /// - Parameters:
  ///   - vaultRuntime: The sole application process owner of catalog and
  ///     collaboration-share state.
  ///   - systemNotificationAuthorization: The separate app-scoped owner of
  ///     contextual notification authorization.
  ///   - container: The container whose system sharing UI callbacks this
  ///     instance observes. Tests may supply a container with the same shape.
  init(
    vaultRuntime: JournalVaultRuntime,
    systemNotificationAuthorization: SystemNotificationAuthorization,
    container: CKContainer = CKContainer(identifier: VaultCloudKitContainer.identifier)
  ) {
    self.vaultRuntime = vaultRuntime
    self.systemNotificationAuthorization = systemNotificationAuthorization
    observer = CKSystemSharingUIObserver(container: container)

    observer.systemSharingUIDidSaveShareBlock = { [weak self] recordID, result in
      Task { @MainActor [weak self] in
        await self?.receiveSystemShareSave(recordID: recordID, result: result)
      }
    }
    observer.systemSharingUIDidStopSharingBlock = { [weak self] recordID, result in
      Task { @MainActor [weak self] in
        await self?.receiveSystemSharingStop(recordID: recordID, result: result)
      }
    }
  }

  /// Starts tracking one initial owner-invite presentation.
  ///
  /// Starting a newer presentation replaces any unfinished one. Subsequent
  /// callbacks carry this ID from the SwiftUI presentation, so a delayed
  /// callback from the old sheet cannot prompt for notifications.
  func beginOwnerSharePresentation(for vaultID: VaultID) -> UUID {
    let presentation = VaultOwnerSharePresentationLifecycle(vaultID: vaultID)
    ownerSharePresentation = presentation
    pendingPrimerSessionID = nil
    return presentation.id
  }

  /// Records whether the platform sharing activity completed successfully.
  ///
  /// A cancelled activity terminally discards the session even if CloudKit
  /// later reports an unrelated saved share for the same vault.
  func noteActivityCompletion(for presentationID: UUID, completed: Bool) {
    guard var presentation = matchingOwnerSharePresentation(id: presentationID) else {
      return
    }

    presentation.recordActivityCompletion(completed)
    guard presentation.isTerminal == false else {
      clearOwnerSharePresentation(id: presentationID)
      return
    }

    ownerSharePresentation = presentation
    requestPrimerIfReady()
  }

  /// Records that the SwiftUI share presentation has been dismissed.
  ///
  /// Dismissal and activity completion arrive in either order across platforms,
  /// so dismissal alone is intentionally non-terminal. A later explicit
  /// cancellation still clears the session; a later successful completion can
  /// combine with a confirmed system save to earn a primer.
  func notePresentationDismissed(for presentationID: UUID) {
    guard var presentation = matchingOwnerSharePresentation(id: presentationID) else {
      return
    }

    presentation.recordPresentationDismissal()
    ownerSharePresentation = presentation
    requestPrimerIfReady()
  }

  /// Discards an initial owner-invite presentation after a UI-level error.
  ///
  /// The system observer may still refresh collaboration state later, but this
  /// terminal session cannot create a notification primer.
  func cancelOwnerSharePresentation(for presentationID: UUID) {
    clearOwnerSharePresentation(id: presentationID)
  }

  private func receiveSystemShareSave(
    recordID: CKRecord.ID,
    result: Result<CKShare, any Error>
  ) async {
    let vaultID = VaultID(zoneName: recordID.zoneID.zoneName)

    guard case .success(let share) = result else {
      if var presentation = ownerSharePresentation, presentation.vaultID == vaultID {
        presentation.recordSystemShareFailure()
        ownerSharePresentation = presentation
        clearOwnerSharePresentation(id: presentation.id)
      }
      return
    }

    await vaultRuntime.noteSystemSharingShareSaved(share, for: vaultID)

    guard let vaultID, var presentation = ownerSharePresentation,
      presentation.vaultID == vaultID
    else {
      return
    }

    presentation.recordSystemShareSave()
    ownerSharePresentation = presentation
    requestPrimerIfReady()
  }

  private func receiveSystemSharingStop(
    recordID: CKRecord.ID,
    result: Result<Void, any Error>
  ) async {
    guard case .success = result else {
      return
    }

    guard let vaultID = VaultID(zoneName: recordID.zoneID.zoneName) else {
      await vaultRuntime.refreshCollaborationShares()
      return
    }

    await vaultRuntime.noteSharingStopped(for: vaultID)

    if ownerSharePresentation?.vaultID == vaultID {
      clearOwnerSharePresentation(id: ownerSharePresentation?.id)
    }
  }

  private func requestPrimerIfReady() {
    guard let presentation = ownerSharePresentation,
      presentation.isReadyForPrimer,
      pendingPrimerSessionID == nil
    else {
      return
    }

    let presentationID = presentation.id
    let vaultID = presentation.vaultID
    pendingPrimerSessionID = presentationID

    Task { @MainActor [weak self] in
      guard let self else { return }

      guard case .refreshed = await vaultRuntime.refreshCollaborationShares() else {
        if pendingPrimerSessionID == presentationID {
          clearOwnerSharePresentation(id: presentationID)
        }
        return
      }

      guard
        pendingPrimerSessionID == presentationID,
        let currentPresentation = matchingOwnerSharePresentation(id: presentationID),
        currentPresentation.isReadyForPrimer,
        let descriptor = vaultRuntime.vaults.first(where: { $0.vaultID == vaultID }),
        descriptor.ownership == .owned,
        descriptor.participantCount > 1
      else {
        if pendingPrimerSessionID == presentationID {
          clearOwnerSharePresentation(id: presentationID)
        }
        return
      }

      // Consume the session before presenting the primer, making all late
      // system/UI callbacks no-ops for notification authorization.
      clearOwnerSharePresentation(id: presentationID)
      await systemNotificationAuthorization.offerPrimer(
        after: .ownerShareSavedAndDismissed(.init(descriptor: descriptor))
      )
    }
  }

  private func matchingOwnerSharePresentation(
    id: UUID
  ) -> VaultOwnerSharePresentationLifecycle? {
    guard ownerSharePresentation?.id == id else { return nil }
    return ownerSharePresentation
  }

  private func clearOwnerSharePresentation(id: UUID?) {
    guard let id, ownerSharePresentation?.id == id else { return }
    ownerSharePresentation = nil
    if pendingPrimerSessionID == id {
      pendingPrimerSessionID = nil
    }
  }
}

/// The order-independent lifecycle facts required before an owner share can
/// request Tinycurve's contextual notification primer.
///
/// This is intentionally a value type without CloudKit or UI dependencies so
/// tests can lock the cancellation and late-callback contract independently of
/// the system share sheet.
struct VaultOwnerSharePresentationLifecycle: Equatable {

  /// Result of the platform sharing activity.
  enum ActivityResult: Equatable {
    /// The platform has not yet reported whether the activity completed.
    case pending

    /// The selected sharing service completed successfully.
    case completed

    /// The user cancelled the activity or the presentation reported an error.
    case cancelled
  }

  /// Unique presentation identity used to reject callbacks from older sheets.
  let id: UUID

  /// Vault whose saved share is being sent through the system activity.
  let vaultID: VaultID

  /// Most recent activity outcome, kept independent from the sheet dismissal.
  private(set) var activityResult: ActivityResult = .pending

  /// Whether SwiftUI has removed the presentation from the visible hierarchy.
  private(set) var didDismissPresentation = false

  /// Whether `CKSystemSharingUIObserver` confirmed a successful share save.
  private(set) var didObserveSystemShareSave = false

  init(id: UUID = UUID(), vaultID: VaultID) {
    self.id = id
    self.vaultID = vaultID
  }

  /// Whether the lifecycle has been explicitly cancelled and cannot recover.
  var isTerminal: Bool {
    activityResult == .cancelled
  }

  /// Whether all independent system/UI facts required for a primer are known.
  var isReadyForPrimer: Bool {
    activityResult == .completed
      && didDismissPresentation
      && didObserveSystemShareSave
  }

  /// Records the platform activity result.
  mutating func recordActivityCompletion(_ completed: Bool) {
    guard isTerminal == false else { return }
    activityResult = completed ? .completed : .cancelled
  }

  /// Records the SwiftUI presentation boundary independently of activity state.
  mutating func recordPresentationDismissal() {
    guard isTerminal == false else { return }
    didDismissPresentation = true
  }

  /// Records a successful callback from `CKSystemSharingUIObserver`.
  mutating func recordSystemShareSave() {
    guard isTerminal == false else { return }
    didObserveSystemShareSave = true
  }

  /// Marks a failed system save as terminal before a later callback can be
  /// associated with this presentation's vault.
  mutating func recordSystemShareFailure() {
    activityResult = .cancelled
  }
}
