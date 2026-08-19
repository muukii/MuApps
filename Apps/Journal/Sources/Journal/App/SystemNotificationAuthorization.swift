import CloudKit
import Foundation
import JournalVault
import OSLog
import Observation
import UserNotifications

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

/// App-scoped owner for Tinycurve's system-notification authorization and
/// foreground presentation policy.
///
/// This is intentionally separate from `JournalNotificationCenter`: that type
/// renders transient in-app feedback, while this controller owns only the
/// operating system's permission, APNs registration, and direct CloudKit Pulse
/// notification presentation. It never creates local notifications or sends a
/// device token to an app-operated server.
@MainActor
@Observable
final class SystemNotificationAuthorization: NSObject, UNUserNotificationCenterDelegate {

  /// The current user-visible system-notification capability.
  ///
  /// `unresolved` is used only while the controller has not read the system
  /// settings. `enabled` preserves both delivery style and the individual
  /// alert/sound settings so Settings can explain a partially enabled state.
  enum Status: Equatable, Sendable {
    case unresolved
    case notDetermined
    case denied
    case enabled(Delivery)

    /// Delivery mode granted by the system.
    enum Delivery: Equatable, Sendable {
      /// Notifications may be delivered immediately when the user's alert
      /// settings permit it.
      case immediate(alert: Bool, sound: Bool)

      /// The system accepts notifications but delivers them quietly.
      case quiet(alert: Bool, sound: Bool)

      /// Whether the user currently permits alert presentation.
      var isAlertEnabled: Bool {
        switch self {
        case .immediate(let alert, _), .quiet(let alert, _):
          alert
        }
      }

      /// Whether the user currently permits notification sound.
      var isSoundEnabled: Bool {
        switch self {
        case .immediate(_, let sound), .quiet(_, let sound):
          sound
        }
      }
    }
  }

  /// One shared controller is retained for the application's full lifetime.
  ///
  /// The app delegate obtains this instance before launch completes to install
  /// it as `UNUserNotificationCenter`'s delegate. SwiftUI receives the same
  /// instance explicitly through the environment.
  static let shared = SystemNotificationAuthorization()

  /// Changes whenever a contextual primer is queued, claimed, released, or
  /// resolved by a window scene.
  ///
  /// Permission is app-scoped, but alert presentation is scene-scoped. SwiftUI
  /// scenes observe this revision and only an active scene can claim the one
  /// pending primer request.
  private(set) var primerPresentationRevision = UUID()

  /// Last authorization state read from `UNUserNotificationCenter`.
  private(set) var status: Status = .unresolved

  @ObservationIgnored private let notificationCenter: UNUserNotificationCenter
  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private var primerPresentation = SystemNotificationPrimerPresentation()
  @ObservationIgnored
  private let notificationSettingsSnapshot:
    @MainActor () async -> SystemNotificationAuthorizationSnapshot
  @ObservationIgnored private let remoteRegistration: @MainActor () -> Void
  @ObservationIgnored private static let logger = Logger(
    subsystem: "app.muukii.journal",
    category: "SystemNotificationAuthorization"
  )

  /// Creates an authorization controller.
  ///
  /// The two closures retain the operating-system boundary at one app-scoped
  /// owner while allowing deterministic tests to model a denied alert state
  /// without disabling APNs transport.
  init(
    notificationCenter: UNUserNotificationCenter = .current(),
    defaults: UserDefaults = .standard,
    notificationSettingsSnapshot:
      @escaping @MainActor () async -> SystemNotificationAuthorizationSnapshot = {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return .init(settings: settings)
      },
    remoteRegistration: @escaping @MainActor () -> Void = {
      #if canImport(UIKit)
        UIApplication.shared.registerForRemoteNotifications()
      #elseif canImport(AppKit)
        NSApplication.shared.registerForRemoteNotifications()
      #endif
    }
  ) {
    self.notificationCenter = notificationCenter
    self.defaults = defaults
    self.notificationSettingsSnapshot = notificationSettingsSnapshot
    self.remoteRegistration = remoteRegistration
    super.init()
  }

  /// Installs the foreground notification delegate before application launch
  /// completes. The system retains this delegate weakly, so the app-scoped
  /// `shared` owner is required for the lifetime of the process.
  func installDelegate() {
    notificationCenter.delegate = self
  }

  /// Re-reads system notification settings and retries APNs registration.
  ///
  /// The app calls this on launch and whenever its scene becomes active because
  /// Settings changes can occur while Tinycurve is backgrounded. APNs device
  /// registration is independent of alert authorization: CloudKit's silent
  /// sync pushes must continue to reach a user who denies visible alerts.
  /// Re-registering is intentional because a previous registration may have
  /// failed transiently.
  func refresh() async {
    await refreshSettings()
    registerForRemoteNotifications()
  }

  /// Re-reads system notification settings without changing APNs transport.
  ///
  /// App launch registers with APNs from the application delegate before
  /// SwiftUI starts its root scene. This separate operation lets that root
  /// render current Settings state without issuing a redundant registration.
  func refreshSettings() async {
    status = .init(snapshot: await notificationSettingsSnapshot())
  }

  /// Requests only the alert and sound capabilities used by shared-Vault Pulse
  /// notifications. Tinycurve never requests badge permission.
  func requestAuthorization() async {
    if case .unresolved = status {
      await refresh()
    }

    guard case .notDetermined = status else { return }

    do {
      _ = try await notificationCenter.requestAuthorization(options: [.alert, .sound])
    } catch {
      Self.logger.error(
        "Notification authorization request failed: \(error.localizedDescription, privacy: .public)"
      )
    }

    await refresh()
  }

  /// Shows the in-app primer when this is a valid collaboration boundary and
  /// the user has not deferred it for this install.
  ///
  /// This method never invokes the system prompt directly. The primer's Enable
  /// action owns that decision so a user can understand why notifications are
  /// useful before the operating system asks.
  func offerPrimer(after trigger: SystemNotificationPrimerTrigger) async {
    await refresh()

    guard
      SystemNotificationPrimerPolicy.shouldOfferPrimer(
        for: status,
        trigger: trigger,
        hasDeferredForInstall: hasDeferredPrimerForInstall
      )
    else {
      return
    }

    if primerPresentation.enqueue() {
      recordPrimerPresentationChange()
    }
  }

  /// Marks the contextual primer as deferred for this install without asking
  /// the system for permission. Future automatic collaboration boundaries do
  /// not present it again.
  func deferPrimer() {
    defaults.set(true, forKey: SystemNotificationPrimerDeferral.defaultsKey)
    if primerPresentation.resolve() {
      recordPrimerPresentationChange()
    }
  }

  /// Dismisses the current primer without changing the user's deferral choice.
  /// The explicit Not Now action is the only path that records a deferral.
  func dismissPrimer() {
    if primerPresentation.resolve() {
      recordPrimerPresentationChange()
    }
  }

  /// Hides the primer and then requests authorization from the user-selected
  /// Enable action.
  func requestAuthorizationFromPrimer() async {
    if primerPresentation.resolve() {
      recordPrimerPresentationChange()
    }
    await requestAuthorization()
  }

  /// Lets one active Window scene present the app-scoped primer request.
  ///
  /// Returning `true` transfers presentation ownership to `sceneID`; all
  /// other windows receive `false` until that scene resolves or releases the
  /// request. The user-facing permission state remains shared by every scene.
  func claimPrimer(
    for sceneID: UUID,
    whenSceneIsActive isActive: Bool
  ) -> Bool {
    guard primerPresentation.claim(for: sceneID, whenSceneIsActive: isActive) else {
      return false
    }
    recordPrimerPresentationChange()
    return true
  }

  /// Returns a still-pending primer to another active scene when its original
  /// presenter disappears before the user makes a choice.
  func releasePrimerClaim(for sceneID: UUID) {
    if primerPresentation.releaseClaim(for: sceneID) {
      recordPrimerPresentationChange()
    }
  }

  /// Defers a primer that the specified scene currently owns.
  func deferPrimer(from sceneID: UUID) {
    guard primerPresentation.resolve(claimedBy: sceneID) else { return }
    defaults.set(true, forKey: SystemNotificationPrimerDeferral.defaultsKey)
    recordPrimerPresentationChange()
  }

  /// Dismisses a primer that the specified scene currently owns without
  /// recording an install-wide Not Now choice.
  func dismissPrimer(from sceneID: UUID) {
    guard primerPresentation.resolve(claimedBy: sceneID) else { return }
    recordPrimerPresentationChange()
  }

  /// Requests authorization from a primer that the specified scene owns.
  func requestAuthorizationFromPrimer(from sceneID: UUID) async {
    guard primerPresentation.resolve(claimedBy: sceneID) else { return }
    recordPrimerPresentationChange()
    await requestAuthorization()
  }

  /// Opens the OS notification settings without relying on undocumented URL
  /// schemes. iOS uses Apple's documented app notification-settings URL; native
  /// macOS opens System Settings at its general entry point.
  func openSystemNotificationSettings() {
    #if canImport(UIKit)
      guard let settingsURL = URL(string: UIApplication.openNotificationSettingsURLString) else {
        return
      }
      UIApplication.shared.open(settingsURL)
    #elseif canImport(AppKit)
      let settingsURL = URL(
        filePath: "/System/Applications/System Settings.app",
        directoryHint: .isDirectory
      )
      NSWorkspace.shared.open(settingsURL)
    #endif
  }

  /// Records an APNs registration failure for diagnostics. The next active
  /// refresh retries registration; no token is cached, uploaded, or used to
  /// unregister from notifications.
  func noteRemoteRegistrationFailure(_ error: any Error) {
    Self.logger.error(
      "Remote notification registration failed: \(error.localizedDescription, privacy: .public)")
  }

  /// Whether this install has selected the primer's Not Now action.
  var hasDeferredPrimerForInstall: Bool {
    defaults.bool(forKey: SystemNotificationPrimerDeferral.defaultsKey)
  }

  private func recordPrimerPresentationChange() {
    primerPresentationRevision = UUID()
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler:
      @escaping @Sendable (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler(SystemNotificationForegroundPolicy.presentationOptions(for: notification))
  }

  /// Handles a system notification tap without inferring a Vault or Card from
  /// a `CKDatabaseNotification`. Normal launch-time sync remains authoritative.
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping @Sendable () -> Void
  ) {
    completionHandler()
  }

  /// Registers this device with APNs regardless of visible-notification
  /// authorization.
  ///
  /// The registration supports both direct visible Pulse pushes and CloudKit's
  /// silent synchronization transport. It never stores or uploads the device
  /// token, and Tinycurve never unregisters it based on an alert choice.
  func registerForRemoteNotifications() {
    remoteRegistration()
  }
}

/// A lightweight, testable snapshot of system notification settings.
///
/// `UNNotificationSettings` has no public initializer, so this value isolates
/// the state mapping from UserNotifications while retaining all data Settings
/// needs to display authorization accurately.
struct SystemNotificationAuthorizationSnapshot: Equatable, Sendable {

  /// Authorization categories that affect Tinycurve's notification behavior.
  enum Authorization: Equatable, Sendable {
    case notDetermined
    case denied
    case authorized
    case provisional
    case ephemeral
  }

  /// A single system interaction setting used by Tinycurve's UI projection.
  enum Interaction: Equatable, Sendable {
    case enabled
    case disabled
  }

  let authorization: Authorization
  let alert: Interaction
  let sound: Interaction

  init(
    authorization: Authorization,
    alert: Interaction,
    sound: Interaction
  ) {
    self.authorization = authorization
    self.alert = alert
    self.sound = sound
  }

  init(settings: UNNotificationSettings) {
    self.init(
      authorization: Self.authorization(from: settings.authorizationStatus),
      alert: Self.interaction(from: settings.alertSetting),
      sound: Self.interaction(from: settings.soundSetting)
    )
  }

  private static func authorization(
    from status: UNAuthorizationStatus
  ) -> Authorization {
    switch status {
    case .notDetermined:
      .notDetermined
    case .denied:
      .denied
    case .authorized:
      .authorized
    case .provisional:
      .provisional
    case .ephemeral:
      .ephemeral
    @unknown default:
      .denied
    }
  }

  private static func interaction(
    from setting: UNNotificationSetting
  ) -> Interaction {
    switch setting {
    case .enabled:
      .enabled
    case .disabled, .notSupported:
      .disabled
    @unknown default:
      .disabled
    }
  }
}

extension SystemNotificationAuthorization.Status {

  init(snapshot: SystemNotificationAuthorizationSnapshot) {
    let isAlertEnabled: Bool
    switch snapshot.alert {
    case .enabled:
      isAlertEnabled = true
    case .disabled:
      isAlertEnabled = false
    }

    let isSoundEnabled: Bool
    switch snapshot.sound {
    case .enabled:
      isSoundEnabled = true
    case .disabled:
      isSoundEnabled = false
    }

    switch snapshot.authorization {
    case .notDetermined:
      self = .notDetermined
    case .denied:
      self = .denied
    case .authorized, .ephemeral:
      self = .enabled(.immediate(alert: isAlertEnabled, sound: isSoundEnabled))
    case .provisional:
      self = .enabled(.quiet(alert: isAlertEnabled, sound: isSoundEnabled))
    }
  }
}

/// Collaboration facts evaluated before showing the automatic notification
/// primer for a Vault that is already open.
///
/// The boolean deliberately models ownership rather than `isShared`: an owner
/// can have a prepared share with no other participant, which must not prompt.
struct SystemNotificationPrimerEligibility: Equatable, Sendable {
  let isParticipant: Bool
  let participantCount: Int

  init(isParticipant: Bool, participantCount: Int) {
    self.isParticipant = isParticipant
    self.participantCount = participantCount
  }

  init(descriptor: VaultDescriptor) {
    switch descriptor.ownership {
    case .participant:
      isParticipant = true
    case .owned:
      isParticipant = false
    }
    participantCount = descriptor.participantCount
  }

  /// Whether an open Vault has at least one other person who may create a
  /// participant-visible Pulse.
  var representsActualCollaboration: Bool {
    if isParticipant {
      return true
    }
    return participantCount > 1
  }
}

/// Product boundaries that may offer Tinycurve's contextual notification primer.
enum SystemNotificationPrimerTrigger: Equatable, Sendable {
  /// The owner saved a CloudKit share, dismissed its UI, and then re-read the
  /// catalog's actual collaboration facts.
  case ownerShareSavedAndDismissed(SystemNotificationPrimerEligibility)

  /// A participant accepted a share and its first shared-zone import completed.
  case participantInitialImportCompleted

  /// An existing user opened a Vault whose collaboration facts are known.
  case existingCollaborativeVaultOpened(SystemNotificationPrimerEligibility)
}

/// Pure product policy for deciding whether an automatic primer is appropriate.
enum SystemNotificationPrimerPolicy {

  /// Whether an existing-vault primer may inspect a catalog descriptor after a
  /// collaboration-share refresh.
  ///
  /// A failed refresh deliberately returns `false`: cached ownership and
  /// participant count are presentation data, not proof that the vault remains
  /// actual collaboration at this moment.
  static func shouldEvaluateExistingVault(
    after refreshResult: JournalVaultRuntime.CollaborationShareRefreshResult
  ) -> Bool {
    switch refreshResult {
    case .refreshed:
      true
    case .failed:
      false
    }
  }

  static func shouldOfferPrimer(
    for status: SystemNotificationAuthorization.Status,
    trigger: SystemNotificationPrimerTrigger,
    hasDeferredForInstall: Bool
  ) -> Bool {
    guard hasDeferredForInstall == false else { return false }

    guard case .notDetermined = status else { return false }

    return switch trigger {
    case .ownerShareSavedAndDismissed(let eligibility):
      eligibility.representsActualCollaboration
    case .participantInitialImportCompleted:
      true
    case .existingCollaborativeVaultOpened(let eligibility):
      eligibility.representsActualCollaboration
    }
  }
}

/// Persisted install-local state for a contextual-primer deferral.
private enum SystemNotificationPrimerDeferral {
  static let defaultsKey = "tinycurve.system-notification-primer.deferred"
}

/// Scene-presentation state for one app-scoped contextual notification primer.
///
/// This value models the small ownership protocol separately from
/// `UNUserNotificationCenter`: an app can have many active macOS windows, but
/// exactly one can present a given primer request. The request remains pending
/// if its presenting scene disappears, allowing another active scene to claim
/// it without duplicating the system-permission rationale.
struct SystemNotificationPrimerPresentation: Equatable {

  /// Stable identity for the pending request, if any.
  private(set) var requestID: UUID?

  /// Scene that currently owns visible presentation, if any.
  private(set) var claimedSceneID: UUID?

  /// Queues one request without replacing an in-flight user decision.
  @discardableResult
  mutating func enqueue(id: UUID = UUID()) -> Bool {
    guard requestID == nil else { return false }
    requestID = id
    return true
  }

  /// Claims the request only for an active scene and only when no other scene
  /// has already become the single presenter.
  @discardableResult
  mutating func claim(
    for sceneID: UUID,
    whenSceneIsActive isActive: Bool
  ) -> Bool {
    guard isActive, requestID != nil, claimedSceneID == nil else { return false }
    claimedSceneID = sceneID
    return true
  }

  /// Releases a presenter's ownership while preserving the queued request.
  @discardableResult
  mutating func releaseClaim(for sceneID: UUID) -> Bool {
    guard claimedSceneID == sceneID else { return false }
    claimedSceneID = nil
    return true
  }

  /// Resolves the request entirely, optionally requiring the owning scene.
  @discardableResult
  mutating func resolve(claimedBy sceneID: UUID? = nil) -> Bool {
    guard requestID != nil else { return false }
    if let sceneID, claimedSceneID != sceneID {
      return false
    }
    requestID = nil
    claimedSceneID = nil
    return true
  }
}

/// Data needed to identify a foreground CloudKit Pulse without inferring
/// behavior for unrelated notifications.
nonisolated struct SystemNotificationForegroundPayload: Equatable, Sendable {
  let subscriptionID: String?
}

/// Foreground presentation policy for direct CloudKit notifications.
nonisolated enum SystemNotificationForegroundPolicy {

  /// Decides system presentation without using current Vault, scene, or app UI
  /// state. A known visible Pulse always uses the requested system UI; an
  /// unknown notification gets no new foreground behavior from Tinycurve.
  static func presentationOptions(
    for payload: SystemNotificationForegroundPayload
  ) -> UNNotificationPresentationOptions {
    if VaultNotificationPulseSubscription.isVisibleNotificationSubscription(payload.subscriptionID)
    {
      return [.banner, .list, .sound]
    }

    return []
  }

  /// Extracts the direct CloudKit subscription identity from a received system
  /// notification and routes it through the pure presentation policy.
  static func presentationOptions(
    for notification: UNNotification
  ) -> UNNotificationPresentationOptions {
    let content = notification.request.content
    let cloudKitNotification =
      CKNotification(
        fromRemoteNotificationDictionary: content.userInfo
      ) as? CKDatabaseNotification
    return presentationOptions(
      for: SystemNotificationForegroundPayload(
        subscriptionID: cloudKitNotification?.subscriptionID
      )
    )
  }
}
