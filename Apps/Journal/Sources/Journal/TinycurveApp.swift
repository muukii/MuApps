import AppUIComponents
import CaptureBauhaus
import CaptureDoodle
import CloudKit
import Foundation
import JournalIntents
import JournalVault
import MuColor
import SwiftUI

@main
struct TinycurveApp: App {

  #if os(iOS)
    @UIApplicationDelegateAdaptor(TinycurveAppDelegate.self) private var appDelegate
  #else
    @NSApplicationDelegateAdaptor(TinycurveAppDelegate.self) private var appDelegate
  #endif

  let vaultRuntime: JournalVaultRuntime
  private let systemNotificationAuthorization: SystemNotificationAuthorization
  private let systemSharingCoordinator: VaultSystemSharingCoordinator
  private let sharedWithYouNoticeDeliveryCoordinator: SharedWithYouNoticeDeliveryCoordinator
  private let hasCachedInitialVaultAvailability: Bool
  #if TINYCURVE_PROFILE_IMAGE
    @State private var userProfile: JournalUserProfile
  #endif

  init() {
    systemNotificationAuthorization = .shared
    VideoPlaybackObservationConfiguration.configure()

    #if TINYCURVE_PROFILE_IMAGE
      _userProfile = State(
        initialValue: JournalUserProfile(
          client: .live(containerIdentifier: VaultCloudKitContainer.identifier)
        )
      )
    #endif

    let defaults = UserDefaults.standard
    let hasCachedInitialVaultAvailability = defaults.bool(
      forKey: JournalDefaults.hasResolvedInitialVaultAvailability
    )

    do {
      let vaultRuntime = try TinycurveRuntimeLaunchPolicy.makeVaultRuntime()
      if hasCachedInitialVaultAvailability {
        let preferredVaultID = defaults.string(forKey: JournalDefaults.lastSelectedVaultID)
          .flatMap { VaultID(uuidString: $0) }
        vaultRuntime.restoreCachedLaunchState(preferredVaultID: preferredVaultID)
      }

      self.vaultRuntime = vaultRuntime
      self.systemSharingCoordinator = VaultSystemSharingCoordinator(
        vaultRuntime: vaultRuntime,
        systemNotificationAuthorization: systemNotificationAuthorization
      )
      self.sharedWithYouNoticeDeliveryCoordinator = SharedWithYouNoticeDeliveryCoordinator(
        runtime: vaultRuntime
      )
      self.hasCachedInitialVaultAvailability = hasCachedInitialVaultAvailability
    } catch {
      fatalError("Failed to create Journal vault runtime: \(error)")
    }
  }

  var body: some Scene {
    WindowGroup {
      Group {
        #if DEBUG
          switch TinycurveDebugLaunchRoute.activeRoute {
          case .textAnimationSandbox:
            TinycurveTextAnimationSandbox()

          case .bookInputMorphSandbox(let initialState):
            BookInputMorphSandbox(initialState: initialState)
              .preferredColorScheme(.dark)

          case .bookAttachmentMenuPreview:
            BookAttachmentMenuPreview(initialMenuState: .expanded)
              .preferredColorScheme(.dark)

          case nil:
            JournalSceneAppearanceHost {
              RootView(
                vaultRuntime: vaultRuntime,
                hasCachedInitialVaultAvailability: hasCachedInitialVaultAvailability,
                systemNotificationAuthorization: systemNotificationAuthorization,
                systemSharingCoordinator: systemSharingCoordinator,
                sharedWithYouNoticeDeliveryCoordinator: sharedWithYouNoticeDeliveryCoordinator
              )
              .task { DoodleHaptics.prepareForDrawing() }
            }
          }
        #else
          JournalSceneAppearanceHost {
            RootView(
              vaultRuntime: vaultRuntime,
              hasCachedInitialVaultAvailability: hasCachedInitialVaultAvailability,
              systemNotificationAuthorization: systemNotificationAuthorization,
              systemSharingCoordinator: systemSharingCoordinator,
              sharedWithYouNoticeDeliveryCoordinator: sharedWithYouNoticeDeliveryCoordinator
            )
            .task { DoodleHaptics.prepareForDrawing() }
          }
        #endif
      }
      #if TINYCURVE_PROFILE_IMAGE
        // The unfinished public-profile client exists only in the explicitly
        // enabled development build; production configurations own no instance.
        .environment(userProfile)
      #endif
    }

    #if os(macOS)
      Settings {
        JournalSceneAppearanceHost {
          #if TINYCURVE_PROFILE_IMAGE
            TinycurveSettingsSceneRoot(
              vaultRuntime: vaultRuntime,
              systemNotificationAuthorization: systemNotificationAuthorization,
              userProfile: userProfile
            )
          #else
            TinycurveSettingsSceneRoot(
              vaultRuntime: vaultRuntime,
              systemNotificationAuthorization: systemNotificationAuthorization
            )
          #endif
        }
      }
    #endif
  }
}

#if os(macOS)
  /// Supplies the app-scoped runtime and accent palette to the independent
  /// macOS Settings content.
  ///
  /// `JournalSceneAppearanceHost` is installed separately at the Settings scene
  /// boundary because independent scenes don't inherit the main window's environment.
  private struct TinycurveSettingsSceneRoot: View {

    let vaultRuntime: JournalVaultRuntime
    let systemNotificationAuthorization: SystemNotificationAuthorization
    #if TINYCURVE_PROFILE_IMAGE
      let userProfile: JournalUserProfile
    #endif

    @AppStorage(JournalDefaults.accentColorID)
    private var accentColorID: String = AccentColor.default.id

    var body: some View {
      PrimaryContainer(accentColor: AccentColor.with(id: accentColorID)) {
        SettingsScreen()
      }
      .environment(vaultRuntime)
      // Settings is an independent native macOS scene. Explicitly inject the
      // same app-lifetime system authorization owner as the main window.
      .environment(systemNotificationAuthorization)
      #if TINYCURVE_PROFILE_IMAGE
        // A macOS Settings scene does not inherit the main window's environment.
        // Inject the same app-lifetime public profile model only for the
        // development configuration that exposes its Settings destination.
        .environment(userProfile)
      #endif
      .frame(minWidth: 520, minHeight: 520)
    }
  }
#endif

#if DEBUG
  /// Launch arguments for opening isolated Journal prototype surfaces.
  private enum TinycurveDebugLaunchRoute {

    /// Debug-only prototype roots supported by Journal launches.
    enum Route {

      /// Opens the isolated TextRenderer appearance-animation stage.
      case textAnimationSandbox

      /// Opens the minimal matched-geometry playground based on the Book input sample.
      case bookInputMorphSandbox(initialState: BookInputMorphSandbox.InitialState)

      /// Opens the fuller Book attachment menu prototype.
      case bookAttachmentMenuPreview
    }

    /// Opens the minimal Book input morph sandbox as the app root.
    private static let bookInputMorphSandboxArgument = "-BookInputMorphSandbox"

    /// Opens the isolated TextRenderer appearance-animation stage as the app root.
    private static let textAnimationSandboxArgument = "-TextAnimationSandbox"

    /// Opens the minimal Book input morph sandbox in its expanded state.
    private static let bookInputMorphSandboxExpandedArgument = "-BookInputMorphSandboxExpanded"

    /// Opens the Book attachment menu prototype as the app root.
    private static let bookAttachmentMenuPreviewArgument = "-BookAttachmentMenuPreview"

    /// Prototype route requested by the current debug launch, if any.
    static var activeRoute: Route? {
      let arguments = ProcessInfo.processInfo.arguments

      if arguments.contains(textAnimationSandboxArgument) {
        return .textAnimationSandbox
      }

      if arguments.contains(bookInputMorphSandboxExpandedArgument) {
        return .bookInputMorphSandbox(initialState: .expanded)
      }

      if arguments.contains(bookInputMorphSandboxArgument) {
        return .bookInputMorphSandbox(initialState: .collapsed)
      }

      if arguments.contains(bookAttachmentMenuPreviewArgument) {
        return .bookAttachmentMenuPreview
      }

      return nil
    }
  }
#endif

/// Reads the persisted accent and applies the root `MuColor` palette.
///
/// `JournalSceneAppearanceHost` supplies the scene color scheme before this view
/// resolves `PrimaryContainer`, so appearance and palette ownership remain separate.
///
/// Also the root router: a fresh install blocks on initial vault discovery, while
/// later launches restore the local vault first and reconcile CloudKit afterward.
private struct RootView: View {

  /// Top-level app routes derived from persisted bootstrap state and the vault runtime.
  private enum RootRoute: Equatable {
    /// A fresh install is checking whether CloudKit has existing vaults to recover.
    case loading

    /// The user has completed onboarding and enters the persistent Journal home.
    case home

    /// No local or remote vault state exists and onboarding has not been completed.
    case newUser
  }

  /// Launch-only gate for activating a vault before the persistent home appears.
  ///
  /// Every non-empty catalog must enter Home with an active vault. The stored
  /// vault is preferred; when it is unavailable, the first catalog vault is
  /// activated instead of exposing an intermediate selection-required screen.
  private enum InitialVaultActivationState: Equatable {
    /// The launch activation decision has not completed yet.
    case pending

    /// The launch activation decision has finished.
    case resolved
  }

  @AppStorage(JournalDefaults.accentColorID)
  private var accentColorID: String = AccentColor.default.id
  @AppStorage(JournalDefaults.hasCompletedOnboarding) private var hasCompletedOnboarding: Bool =
    false
  @AppStorage(JournalDefaults.hasResolvedInitialVaultAvailability)
  private var hasResolvedInitialVaultAvailability: Bool = false
  @AppStorage(JournalDefaults.lastSelectedVaultID) private var lastSelectedVaultID: String = ""
  @Environment(\.scenePhase) private var scenePhase
  @State private var notificationCenter = JournalNotificationCenter()
  @State private var vaultRuntime: JournalVaultRuntime
  private let systemNotificationAuthorization: SystemNotificationAuthorization
  private let systemSharingCoordinator: VaultSystemSharingCoordinator
  private let sharedWithYouNoticeDeliveryCoordinator: SharedWithYouNoticeDeliveryCoordinator
  @State private var initialVaultActivationState: InitialVaultActivationState = .pending
  @State private var systemCaptureRequest: JournalCaptureRequest?
  @State private var systemCaptureRoutingError: SystemCaptureRoutingError?
  @State private var sceneID = UUID()
  @State private var isSystemNotificationPrimerPresented = false

  init(
    vaultRuntime: JournalVaultRuntime,
    hasCachedInitialVaultAvailability: Bool,
    systemNotificationAuthorization: SystemNotificationAuthorization,
    systemSharingCoordinator: VaultSystemSharingCoordinator,
    sharedWithYouNoticeDeliveryCoordinator: SharedWithYouNoticeDeliveryCoordinator
  ) {
    _vaultRuntime = State(initialValue: vaultRuntime)
    self.systemNotificationAuthorization = systemNotificationAuthorization
    self.systemSharingCoordinator = systemSharingCoordinator
    self.sharedWithYouNoticeDeliveryCoordinator = sharedWithYouNoticeDeliveryCoordinator
    _initialVaultActivationState = State(
      initialValue: hasCachedInitialVaultAvailability ? .resolved : .pending
    )
  }

  var body: some View {
    PrimaryContainer(accentColor: AccentColor.with(id: accentColorID)) {
      JournalNotificationHost(center: notificationCenter) {
        switch rootRoute {
        case .loading:
          RootLoadingView()
            .transition(.opacity)

        case .home:
          JournalHomeView(
            systemCaptureRequest: $systemCaptureRequest,
            onSystemCaptureFailure: presentSystemCaptureFailure,
            onActiveVaultChanged: persistActiveVaultSelection
          )
          .transition(.opacity)

        case .newUser:
          OnboardingView(
            onComplete: {
              completeNewUserOnboarding()
            }
          )
          .transition(.opacity)
        }
      }
    }
    .environment(vaultRuntime)
    .environment(systemNotificationAuthorization)
    .environment(systemSharingCoordinator)
    .task {
      await startRootRouting()
      await sharedWithYouNoticeDeliveryCoordinator.start(
        sceneID: sceneID,
        isSceneActive: scenePhase == .active
      )
      claimSystemNotificationPrimerIfAvailable()
    }
    .task { await systemNotificationAuthorization.refreshSettings() }
    .task { await acceptIncomingCloudKitShares() }
    .task { await acceptSystemCaptureRequests() }
    .task(id: systemNotificationAuthorization.primerPresentationRevision) {
      claimSystemNotificationPrimerIfAvailable()
    }
    .onChange(of: scenePhase) { _, phase in
      guard phase == .active else {
        sharedWithYouNoticeDeliveryCoordinator.sceneDidBecomeInactive(sceneID)
        releaseSystemNotificationPrimerIfNeeded()
        return
      }
      Task {
        await sharedWithYouNoticeDeliveryCoordinator.sceneDidBecomeActive(sceneID)
        await resumeAfterSceneActivation()
        await systemNotificationAuthorization.refresh()
        claimSystemNotificationPrimerIfAvailable()
      }
    }
    .onChange(of: initialVaultActivationState) { _, state in
      guard state == .resolved else { return }
      validateSystemCaptureRequestIfPossible()
    }
    .alert(item: $systemCaptureRoutingError) { error in
      Alert(
        title: Text("Quick Capture Is Not Ready"),
        message: Text(error.message),
        dismissButton: .default(Text("OK"))
      )
    }
    .alert(
      "Stay updated with a shared Vault",
      isPresented: Binding(
        get: { isSystemNotificationPrimerPresented },
        set: { isPresented in
          if isPresented == false {
            isSystemNotificationPrimerPresented = false
            systemNotificationAuthorization.dismissPrimer(from: sceneID)
          }
        }
      )
    ) {
      Button("Not Now", role: .cancel) {
        isSystemNotificationPrimerPresented = false
        systemNotificationAuthorization.deferPrimer(from: sceneID)
      }

      Button("Enable Notifications") {
        isSystemNotificationPrimerPresented = false
        Task { await systemNotificationAuthorization.requestAuthorizationFromPrimer(from: sceneID) }
      }
    } message: {
      Text(
        "Get notified when someone adds to a shared Vault. You can change this anytime in Settings."
      )
    }
    .onDisappear {
      sharedWithYouNoticeDeliveryCoordinator.sceneDidBecomeInactive(sceneID)
      releaseSystemNotificationPrimerIfNeeded()
    }
  }

  private func startRootRouting() async {
    await vaultRuntime.start()

    // The environment-scoped resolution is the durable boundary between a
    // first install, which must discover remote vaults before onboarding, and a
    // returning launch, which can trust its local catalog immediately.
    if hasResolvedInitialVaultAvailability {
      await activateInitialVaultIfPossible()
    }

    // Keep recovery on every launch, but on returning launches the root route is
    // already resolved before this network-dependent operation begins.
    await resolveVaultAvailabilityAndActivate()
  }

  /// Rechecks CloudKit after returning from Settings when launch began without
  /// an available iCloud account or deferred account status.
  ///
  /// This is shared by Simulator and device builds. Returning to the app after
  /// a Simulator iCloud sign-in therefore performs the same vault discovery and
  /// foreground activation as a launch that began with iCloud available.
  private func resumeAfterSceneActivation() async {
    if let resolution = vaultRuntime.lastInitialAvailabilityResolution {
      switch resolution {
      case .resolvedWithCloudKit:
        break

      case .resolvedWithoutICloud, .resolvedWithDeferredCloudKit, .unresolved:
        await resolveVaultAvailabilityAndActivate()
      }
    }

    await vaultRuntime.resumeAfterExternalCapture()
  }

  /// Claims the app-scoped primer only from this active scene.
  ///
  /// macOS can keep multiple windows active. The authorization controller
  /// serializes the claim so this view's local alert binding never mirrors into
  /// a second window.
  private func claimSystemNotificationPrimerIfAvailable() {
    guard scenePhase == .active, isSystemNotificationPrimerPresented == false else {
      return
    }
    isSystemNotificationPrimerPresented = systemNotificationAuthorization.claimPrimer(
      for: sceneID,
      whenSceneIsActive: true
    )
  }

  /// Releases a claim if this scene disappears before a user action resolves
  /// it, allowing another active scene to become the single presenter.
  private func releaseSystemNotificationPrimerIfNeeded() {
    guard isSystemNotificationPrimerPresented else { return }
    isSystemNotificationPrimerPresented = false
    systemNotificationAuthorization.releasePrimerClaim(for: sceneID)
  }

  /// Applies a CloudKit availability resolution to app routing and activates
  /// the selected vault after the catalog has been refreshed.
  private func resolveVaultAvailabilityAndActivate() async {
    let resolution = await vaultRuntime.resolveInitialVaultAvailability()

    if vaultRuntime.vaults.isEmpty == false {
      hasCompletedOnboarding = true
    }

    if resolution.isResolved {
      hasResolvedInitialVaultAvailability = true
    }

    await activateInitialVaultIfPossible()
  }

  private var rootRoute: RootRoute {
    guard hasResolvedInitialVaultAvailability else { return .loading }
    guard initialVaultActivationState == .resolved else { return .loading }

    if vaultRuntime.vaults.isEmpty == false || hasCompletedOnboarding {
      return .home
    }

    return .newUser
  }

  private func completeNewUserOnboarding() {
    withAnimation(.smooth) {
      hasCompletedOnboarding = true
    }
  }

  private func activateInitialVaultIfPossible() async {
    defer { initialVaultActivationState = .resolved }

    guard let fallbackVaultID = vaultRuntime.vaults.first?.vaultID else {
      lastSelectedVaultID = ""
      return
    }

    let preferredVaultID: VaultID
    if let storedVaultID = VaultID(uuidString: lastSelectedVaultID),
      vaultRuntime.vaults.contains(where: { $0.vaultID == storedVaultID })
    {
      preferredVaultID = storedVaultID
    } else {
      preferredVaultID = fallbackVaultID
    }

    await vaultRuntime.selectVault(preferredVaultID)
    persistActiveVaultSelection()
  }

  private func persistActiveVaultSelection() {
    guard let selectedVault = vaultRuntime.selectedVault,
      vaultRuntime.selectedVaultState == .active
    else {
      lastSelectedVaultID = ""
      return
    }

    lastSelectedVaultID = selectedVault.vaultID.uuidString
  }

  private func acceptIncomingCloudKitShares() async {
    for await metadata in CloudKitShareAcceptanceRouter.shared.metadataStream() {
      await acceptCloudKitShare(metadata)
    }
  }

  /// Receives capture requests emitted by `UISceneAppIntent` after iOS opens or
  /// activates this process. Validation waits for initial vault recovery so a
  /// cold launch cannot reject a destination that CloudKit is still restoring.
  private func acceptSystemCaptureRequests() async {
    for await request in JournalCaptureRequestCenter.shared.requests() {
      systemCaptureRequest = request
      validateSystemCaptureRequestIfPossible()
    }
  }

  private func validateSystemCaptureRequestIfPossible() {
    guard initialVaultActivationState == .resolved,
      let request = systemCaptureRequest
    else {
      return
    }

    guard let vaultID = request.vaultID else {
      presentSystemCaptureFailure(
        String(
          localized: "Choose a Vault for this action or post once from Tinycurve Share."
        )
      )
      return
    }

    guard let descriptor = vaultRuntime.vaults.first(where: { $0.vaultID == vaultID }) else {
      presentSystemCaptureFailure(
        String(
          localized: "The selected Vault is unavailable. Choose another Vault for this action."
        )
      )
      return
    }

    guard descriptor.permission != .readOnly else {
      presentSystemCaptureFailure(
        String(
          localized:
            "The selected Vault is read-only. Choose a Vault you can edit for this action.")
      )
      return
    }
  }

  private func presentSystemCaptureFailure(_ message: String) {
    systemCaptureRequest = nil
    systemCaptureRoutingError = SystemCaptureRoutingError(message: message)
  }

  private func acceptCloudKitShare(_ metadata: CKShare.Metadata) async {
    do {
      try await vaultRuntime.acceptShare(metadata: metadata)
      await systemNotificationAuthorization.offerPrimer(after: .participantInitialImportCompleted)
      notificationCenter.post(.vaultInviteAccepted)

      if vaultRuntime.selectedVaultState != .active,
        let firstVaultID = vaultRuntime.vaults.first?.vaultID
      {
        await vaultRuntime.selectVault(firstVaultID)
      }
      persistActiveVaultSelection()

      withAnimation(.smooth) {
        hasCompletedOnboarding = true
        hasResolvedInitialVaultAvailability = true
        initialVaultActivationState = .resolved
      }
    } catch {
      notificationCenter.post(.vaultInviteAcceptanceFailed)
    }
  }
}

/// One user-facing failure while routing a system Quick Capture request.
private struct SystemCaptureRoutingError: Identifiable {
  let id = UUID()
  let message: String
}

/// Persistent post-onboarding shell.
///
/// Vault management is presented over this view, so changing or deleting the
/// active vault never replaces the sheet's presenter. A non-empty catalog is
/// expected to have an active vault; the only normal empty state is `noVault`.
private struct JournalHomeView: View {

  @Binding private var systemCaptureRequest: JournalCaptureRequest?
  private let onSystemCaptureFailure: @MainActor @Sendable (String) -> Void
  private let onActiveVaultChanged: @MainActor @Sendable () -> Void

  @Environment(JournalVaultRuntime.self) private var vaultRuntime
  @Environment(SystemNotificationAuthorization.self) private var systemNotificationAuthorization
  #if os(macOS)
    @Environment(\.openSettings) private var openSettings
  #endif

  @State private var isVaultSelectionPresented = false
  @State private var isVaultCreationPresented = false
  #if os(iOS)
    @State private var isSettingsPresented = false
  #endif
  @State private var vaultSheetDetent: PresentationDetent = .medium

  /// Home's transient content projection lives above the vault-specific
  /// Creation identity so changing vaults cannot reset a user selection.
  @State private var selectedHomeContentKind: JournalVault.Card.Kind?

  init(
    systemCaptureRequest: Binding<JournalCaptureRequest?>,
    onSystemCaptureFailure: @escaping @MainActor @Sendable (String) -> Void,
    onActiveVaultChanged: @escaping @MainActor @Sendable () -> Void
  ) {
    _systemCaptureRequest = systemCaptureRequest
    self.onSystemCaptureFailure = onSystemCaptureFailure
    self.onActiveVaultChanged = onActiveVaultChanged
  }

  var body: some View {
    JournalHomeContent(
      state: contentState,
      initialAvailabilityResolution: vaultRuntime.lastInitialAvailabilityResolution,
      systemCaptureRequest: $systemCaptureRequest,
      selectedHomeContentKind: $selectedHomeContentKind,
      onOpenVaults: presentVaultSelection,
      onSelectVaultForSystemCapture: selectVaultForSystemCapture,
      onSystemCaptureFailure: onSystemCaptureFailure,
      onCreateVault: { isVaultCreationPresented = true },
      onRefreshVaults: refreshVaults,
      onRetryVaultActivation: retryVaultActivation,
      onOpenSettings: presentSettings
    )
    .task(
      id: SystemNotificationPrimerOpenIdentity(
        vaultID: vaultRuntime.selectedVault?.vaultID,
        selectedVaultState: vaultRuntime.selectedVaultState
      )
    ) {
      await offerSystemNotificationPrimerAfterCollaborativeVaultOpen()
    }
    .sheet(isPresented: $isVaultSelectionPresented) {
      VaultSelectionView(
        onVaultSelected: finishVaultSelection,
        onClose: { isVaultSelectionPresented = false },
        onActiveVaultChanged: activeVaultChangedInsidePicker
      )
      .appVaultSelectionPresentation(selection: $vaultSheetDetent)
    }
    .sheet(isPresented: $isVaultCreationPresented) {
      VaultCreationSheet(
        onCreate: createVault,
        onCancel: { isVaultCreationPresented = false }
      )
      .presentationBackground(.background)
    }
    #if os(iOS)
      .sheet(isPresented: $isSettingsPresented) {
        SettingsScreen()
        .presentationSizing(.form)
        .presentationBackground(.background)
      }
    #endif
  }

  private var contentState: JournalHomeContentState {
    if vaultRuntime.vaults.isEmpty {
      return .noVault
    }

    switch vaultRuntime.selectedVaultState {
    case .inactive, .opening:
      return .openingVault

    case .active:
      guard let selectedVault = vaultRuntime.selectedVault else {
        return .vaultUnavailable(String(localized: "The selected vault is not available."))
      }
      return .creation(vaultID: selectedVault.vaultID)

    case .failed:
      return .vaultUnavailable(String(localized: "The selected vault is not available."))
    }
  }

  private func presentVaultSelection() {
    vaultSheetDetent = .medium
    isVaultSelectionPresented = true
  }

  /// Opens the platform-native Settings presentation without changing the iOS
  /// sheet used by the existing phone and tablet interface.
  private func presentSettings() {
    #if os(macOS)
      openSettings()
    #else
      isSettingsPresented = true
    #endif
  }

  private func finishVaultSelection() {
    onActiveVaultChanged()
    isVaultSelectionPresented = false
  }

  private func activeVaultChangedInsidePicker() {
    onActiveVaultChanged()
    if vaultRuntime.vaults.isEmpty {
      isVaultSelectionPresented = false
    }
  }

  private func createVault(title: String, icon: VaultIcon) async -> String? {
    guard await vaultRuntime.createVault(title: title, icon: icon) != nil else {
      return vaultRuntime.lastMessage ?? String(localized: "Could not create vault.")
    }

    onActiveVaultChanged()
    isVaultCreationPresented = false
    return nil
  }

  private func refreshVaults() {
    Task { @MainActor in
      await vaultRuntime.refresh()
      await activateFirstVaultIfNeeded()
    }
  }

  private func retryVaultActivation() {
    Task { @MainActor in
      await activateFirstVaultIfNeeded()
    }
  }

  private func selectVaultForSystemCapture(_ vaultID: VaultID) async -> Bool {
    await vaultRuntime.selectVault(vaultID)
    let didSelect =
      vaultRuntime.selectedVault?.vaultID == vaultID
      && vaultRuntime.selectedVaultState == .active
    if didSelect {
      onActiveVaultChanged()
    }
    return didSelect
  }

  private func activateFirstVaultIfNeeded() async {
    guard vaultRuntime.selectedVaultState != .active,
      let firstVaultID = vaultRuntime.vaults.first?.vaultID
    else {
      onActiveVaultChanged()
      return
    }

    await vaultRuntime.selectVault(firstVaultID)
    onActiveVaultChanged()
  }

  /// Offers the existing-user primer only after a Vault is actually open and a
  /// fresh CloudKit collaboration-share refresh confirms participant facts.
  ///
  /// It does not use a cached descriptor or the broader `isShared` presentation
  /// flag: an owner-only prepared share is not notification-worthy
  /// collaboration, and a transient refresh failure is not evidence that an
  /// old participant count remains authoritative.
  private func offerSystemNotificationPrimerAfterCollaborativeVaultOpen() async {
    switch vaultRuntime.selectedVaultState {
    case .active:
      break
    case .inactive, .opening, .failed:
      return
    }

    guard let selectedVaultID = vaultRuntime.selectedVault?.vaultID else {
      return
    }

    let refreshResult = await vaultRuntime.refreshCollaborationShares()
    guard SystemNotificationPrimerPolicy.shouldEvaluateExistingVault(after: refreshResult) else {
      return
    }

    guard
      vaultRuntime.selectedVaultState == .active,
      vaultRuntime.selectedVault?.vaultID == selectedVaultID,
      let descriptor = vaultRuntime.vaults.first(where: {
        $0.vaultID == selectedVaultID
      })
    else {
      return
    }

    await systemNotificationAuthorization.offerPrimer(
      after: .existingCollaborativeVaultOpened(
        .init(descriptor: descriptor)
      )
    )
  }
}

/// Identity for the first-open contextual notification check. A vault switch
/// may keep the runtime in `.active`, so the vault ID and lifecycle state both
/// participate in the task identity.
private struct SystemNotificationPrimerOpenIdentity: Equatable {
  let vaultID: VaultID?
  let selectedVaultState: JournalVaultRuntime.SelectedVaultState
}

/// Render states for the persistent Journal home.
private enum JournalHomeContentState: Equatable {
  /// No local or recovered vault exists, so Creation actions are unavailable.
  case noVault

  /// The runtime is opening the automatically selected vault.
  case openingVault

  /// Creation is backed by the active vault with this stable identity.
  case creation(vaultID: VaultID)

  /// A non-empty catalog exists, but its automatic vault activation failed.
  case vaultUnavailable(String)
}

/// Stateless content switch for `JournalHomeView`.
private struct JournalHomeContent: View {

  let state: JournalHomeContentState
  let initialAvailabilityResolution: VaultInitialAvailabilityResolution?
  @Binding var systemCaptureRequest: JournalCaptureRequest?
  @Binding var selectedHomeContentKind: JournalVault.Card.Kind?
  let onOpenVaults: @MainActor @Sendable () -> Void
  let onSelectVaultForSystemCapture: @MainActor @Sendable (VaultID) async -> Bool
  let onSystemCaptureFailure: @MainActor @Sendable (String) -> Void
  let onCreateVault: @MainActor @Sendable () -> Void
  let onRefreshVaults: @MainActor @Sendable () -> Void
  let onRetryVaultActivation: @MainActor @Sendable () -> Void
  let onOpenSettings: @MainActor @Sendable () -> Void

  var body: some View {
    switch state {
    case .noVault:
      JournalNoVaultView(
        initialAvailabilityResolution: initialAvailabilityResolution,
        onCreateVault: onCreateVault,
        onRefreshVaults: onRefreshVaults,
        onOpenSettings: onOpenSettings
      )

    case .openingVault:
      JournalVaultOpeningView()

    case .creation(let vaultID):
      CreationView(
        systemCaptureRequest: $systemCaptureRequest,
        selectedHomeContentKind: $selectedHomeContentKind,
        onChangeVault: onOpenVaults,
        onSelectVaultForSystemCapture: onSelectVaultForSystemCapture,
        onSystemCaptureFailure: onSystemCaptureFailure
      )
      .id(vaultID)

    case .vaultUnavailable(let message):
      JournalVaultUnavailableView(
        message: message,
        onRetry: onRetryVaultActivation,
        onOpenVaults: onOpenVaults,
        onOpenSettings: onOpenSettings
      )
    }
  }
}

/// Home content shown when the catalog has no vaults.
private struct JournalNoVaultView: View {

  let initialAvailabilityResolution: VaultInitialAvailabilityResolution?
  let onCreateVault: @MainActor @Sendable () -> Void
  let onRefreshVaults: @MainActor @Sendable () -> Void
  let onOpenSettings: @MainActor @Sendable () -> Void

  var body: some View {
    NavigationStack {
      JournalNoVaultContent(
        initialAvailabilityResolution: initialAvailabilityResolution,
        onCreateVault: onCreateVault,
        onRefreshVaults: onRefreshVaults
      )
      .toolbar {
        ToolbarItem(placement: .appTrailingAction) {
          Button(action: onOpenSettings) {
            Image(systemName: "gearshape")
          }
          .accessibilityLabel("Settings")
        }
      }
    }
  }
}

/// Empty-catalog message and recovery actions.
private struct JournalNoVaultContent: View {

  let initialAvailabilityResolution: VaultInitialAvailabilityResolution?
  let onCreateVault: @MainActor @Sendable () -> Void
  let onRefreshVaults: @MainActor @Sendable () -> Void

  var body: some View {
    VStack(spacing: 18) {
      if let initialAvailabilityResolution,
        initialAvailabilityResolution.isCloudKitDeferred
      {
        VaultCloudKitDeferredBanner(resolution: initialAvailabilityResolution)
          .padding(.horizontal, 16)
      }

      ContentUnavailableView {
        Label("No Vaults", systemImage: "shippingbox")
      } description: {
        Text("Create your first vault to start preserving moments.")
      } actions: {
        Button(action: onCreateVault) {
          Label("New Vault", systemImage: "plus")
        }

        Button(action: onRefreshVaults) {
          Label("Refresh", systemImage: "arrow.clockwise")
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.background)
  }
}

/// Transient Home content while the automatically chosen vault is opening.
private struct JournalVaultOpeningView: View {

  var body: some View {
    VStack(spacing: 14) {
      ProgressView()
      Text("Opening Vault")
        .font(.headline)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.background)
  }
}

/// Recovery content for a catalog whose automatic vault activation failed.
private struct JournalVaultUnavailableView: View {

  let message: String
  let onRetry: @MainActor @Sendable () -> Void
  let onOpenVaults: @MainActor @Sendable () -> Void
  let onOpenSettings: @MainActor @Sendable () -> Void

  var body: some View {
    NavigationStack {
      ContentUnavailableView {
        Label("Vault Not Ready", systemImage: "exclamationmark.triangle")
      } description: {
        Text(message)
      } actions: {
        Button(action: onRetry) {
          Label("Retry", systemImage: "arrow.clockwise")
        }

        Button(action: onOpenVaults) {
          Label("Vaults", systemImage: "shippingbox")
        }
      }
      .background(.background)
      .toolbar {
        ToolbarItem(placement: .appTrailingAction) {
          Button(action: onOpenSettings) {
            Image(systemName: "gearshape")
          }
          .accessibilityLabel("Settings")
        }
      }
    }
  }
}

#Preview {
  let vaultRuntime = JournalVaultRuntime.previewRuntime()
  let systemNotificationAuthorization = SystemNotificationAuthorization.shared
  let sharedWithYouNoticeDeliveryCoordinator = SharedWithYouNoticeDeliveryCoordinator(
    runtime: vaultRuntime
  )
  RootView(
    vaultRuntime: vaultRuntime,
    hasCachedInitialVaultAvailability: false,
    systemNotificationAuthorization: systemNotificationAuthorization,
    systemSharingCoordinator: VaultSystemSharingCoordinator(
      vaultRuntime: vaultRuntime,
      systemNotificationAuthorization: systemNotificationAuthorization
    ),
    sharedWithYouNoticeDeliveryCoordinator: sharedWithYouNoticeDeliveryCoordinator
  )
}

private struct RootLoadingView: View {

  var body: some View {
    VStack(spacing: 14) {
      ProgressView()
      Text("Checking Vaults")
        .font(.headline)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.background)
  }
}
