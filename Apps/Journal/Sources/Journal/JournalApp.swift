import AppUIComponents
import CaptureBauhaus
import CaptureDoodle
import CloudKit
import JournalVault
import MuColor
import SwiftUI

@main
struct JournalApp: App {

  #if os(iOS)
  @UIApplicationDelegateAdaptor(JournalAppDelegate.self) private var appDelegate
  #else
  @NSApplicationDelegateAdaptor(JournalAppDelegate.self) private var appDelegate
  #endif

  let vaultRuntime: JournalVaultRuntime

  init() {
    VideoPlaybackObservationConfiguration.configure()

    do {
      vaultRuntime = try JournalVaultRuntime.appGroupCloudKitRuntime()
    } catch {
      fatalError("Failed to create Journal vault runtime: \(error)")
    }
  }

  var body: some Scene {
    WindowGroup {
      #if DEBUG
      switch JournalDebugLaunchRoute.activeRoute {
      case .bookInputMorphSandbox(let initialState):
        BookInputMorphSandbox(initialState: initialState)
          .preferredColorScheme(.dark)

      case .bookAttachmentMenuPreview:
        BookAttachmentMenuPreview(initialMenuState: .expanded)
          .preferredColorScheme(.dark)

      case nil:
        RootView(vaultRuntime: vaultRuntime)
          .task { DoodleHaptics.prepareForDrawing() }
      }
      #else
      RootView(vaultRuntime: vaultRuntime)
        .task { DoodleHaptics.prepareForDrawing() }
      #endif
    }
  }
}

#if DEBUG
/// Launch arguments for opening isolated Journal prototype surfaces.
private enum JournalDebugLaunchRoute {

  /// Debug-only prototype roots supported by Journal launches.
  enum Route {

    /// Opens the minimal matched-geometry playground based on the Book input sample.
    case bookInputMorphSandbox(initialState: BookInputMorphSandbox.InitialState)

    /// Opens the fuller Book attachment menu prototype.
    case bookAttachmentMenuPreview
  }

  /// Opens the minimal Book input morph sandbox as the app root.
  private static let bookInputMorphSandboxArgument = "-BookInputMorphSandbox"

  /// Opens the minimal Book input morph sandbox in its expanded state.
  private static let bookInputMorphSandboxExpandedArgument = "-BookInputMorphSandboxExpanded"

  /// Opens the Book attachment menu prototype as the app root.
  private static let bookAttachmentMenuPreviewArgument = "-BookAttachmentMenuPreview"

  /// Prototype route requested by the current debug launch, if any.
  static var activeRoute: Route? {
    let arguments = ProcessInfo.processInfo.arguments

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

/// Reads the persisted theme and appearance preference, then applies them to the
/// whole app. Kept separate from `JournalApp` so the `@AppStorage` reads live in
/// a `View`, where changes re-render the tree.
///
/// Also the root router: it blocks on loading until initial vault availability
/// and automatic vault activation are resolved, then enters onboarding or the
/// persistent Journal home.
private struct RootView: View {

  /// Top-level app routes derived from persisted bootstrap state and the vault runtime.
  private enum RootRoute: Equatable {
    /// The app is checking whether vault storage and CloudKit recovery are available.
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

  @AppStorage(JournalDefaults.themeID) private var themeID: String = Theme.default.id
  @AppStorage(JournalDefaults.appearancePreferenceID)
  private var appearancePreferenceID: String = JournalAppearancePreference.system.rawValue
  @AppStorage(JournalDefaults.hasCompletedOnboarding) private var hasCompletedOnboarding: Bool = false
  @AppStorage(JournalDefaults.hasResolvedInitialVaultAvailability)
  private var hasResolvedInitialVaultAvailability: Bool = false
  @AppStorage(JournalDefaults.lastSelectedVaultID) private var lastSelectedVaultID: String = ""
  @State private var notificationCenter = JournalNotificationCenter()
  @State private var vaultRuntime: JournalVaultRuntime
  @State private var initialVaultActivationState: InitialVaultActivationState = .pending

  init(vaultRuntime: JournalVaultRuntime) {
    _vaultRuntime = State(initialValue: vaultRuntime)
  }

  var body: some View {
    let appearancePreference = JournalAppearancePreference.with(id: appearancePreferenceID)

    PrimaryContainer(theme: Theme.with(id: themeID)) {
      JournalNotificationHost(center: notificationCenter) {
        switch rootRoute {
        case .loading:
          RootLoadingView()
            .transition(.opacity)

        case .home:
          JournalHomeView(
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
    .preferredColorScheme(appearancePreference.colorScheme)
    .task { await startRootRouting() }
    .task { await acceptIncomingCloudKitShares() }
  }

  private func startRootRouting() async {
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
       vaultRuntime.vaults.contains(where: { $0.vaultID == storedVaultID }) {
      preferredVaultID = storedVaultID
    } else {
      preferredVaultID = fallbackVaultID
    }

    await vaultRuntime.selectVault(preferredVaultID)
    persistActiveVaultSelection()
  }

  private func persistActiveVaultSelection() {
    guard let selectedVault = vaultRuntime.selectedVault,
          vaultRuntime.selectedVaultState == .active else {
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

  private func acceptCloudKitShare(_ metadata: CKShare.Metadata) async {
    do {
      try await vaultRuntime.acceptShare(metadata: metadata)
      notificationCenter.post(.vaultInviteAccepted)

      if vaultRuntime.selectedVaultState != .active,
         let firstVaultID = vaultRuntime.vaults.first?.vaultID {
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

/// Persistent post-onboarding shell.
///
/// Vault management is presented over this view, so changing or deleting the
/// active vault never replaces the sheet's presenter. A non-empty catalog is
/// expected to have an active vault; the only normal empty state is `noVault`.
private struct JournalHomeView: View {

  private let onActiveVaultChanged: @MainActor @Sendable () -> Void

  @Environment(JournalVaultRuntime.self) private var vaultRuntime

  @State private var isVaultSelectionPresented = false
  @State private var isVaultCreationPresented = false
  @State private var isSettingsPresented = false
  @State private var vaultSheetDetent: PresentationDetent = .medium

  init(onActiveVaultChanged: @escaping @MainActor @Sendable () -> Void) {
    self.onActiveVaultChanged = onActiveVaultChanged
  }

  var body: some View {
    JournalHomeContent(
      state: contentState,
      initialAvailabilityResolution: vaultRuntime.lastInitialAvailabilityResolution,
      onOpenVaults: presentVaultSelection,
      onCreateVault: { isVaultCreationPresented = true },
      onRefreshVaults: refreshVaults,
      onRetryVaultActivation: retryVaultActivation,
      onOpenSettings: { isSettingsPresented = true }
    )
    .sheet(isPresented: $isVaultSelectionPresented) {
      VaultSelectionView(
        onVaultSelected: finishVaultSelection,
        onClose: { isVaultSelectionPresented = false },
        onActiveVaultChanged: activeVaultChangedInsidePicker
      )
      .presentationDetents(
        [.medium, .large],
        selection: $vaultSheetDetent
      )
      .presentationDragIndicator(.visible)
      .presentationBackground(.background)
    }
    .sheet(isPresented: $isVaultCreationPresented) {
      VaultCreationSheet(
        onCreate: createVault,
        onCancel: { isVaultCreationPresented = false }
      )
      .presentationBackground(.background)
    }
    .sheet(isPresented: $isSettingsPresented) {
      SettingsScreen()
        .presentationBackground(.background)
    }
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

  private func activateFirstVaultIfNeeded() async {
    guard vaultRuntime.selectedVaultState != .active,
          let firstVaultID = vaultRuntime.vaults.first?.vaultID else {
      onActiveVaultChanged()
      return
    }

    await vaultRuntime.selectVault(firstVaultID)
    onActiveVaultChanged()
  }
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
  let onOpenVaults: @MainActor @Sendable () -> Void
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
      CreationView(onChangeVault: onOpenVaults)
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
        ToolbarItem(placement: .journalTrailingAction) {
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
         initialAvailabilityResolution.isCloudKitDeferred {
        VaultCloudKitDeferredBanner(resolution: initialAvailabilityResolution)
          .padding(.horizontal, 16)
      }

      ContentUnavailableView {
        Label("No Vaults", systemImage: "shippingbox")
      } description: {
        Text("Create your first vault to start making cards.")
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
        ToolbarItem(placement: .journalTrailingAction) {
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
  RootView(vaultRuntime: .previewRuntime())
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
