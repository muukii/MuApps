import AppUIComponents
import CaptureBauhaus
import CaptureDoodle
import CloudKit
import JournalVault
import MuColor
import SwiftUI

@main
struct JournalApp: App {

  @UIApplicationDelegateAdaptor(JournalAppDelegate.self) private var appDelegate

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
      RootView(vaultRuntime: vaultRuntime)
        .task { DoodleHaptics.prepareForDrawing() }
    }
  }
}

/// Reads the persisted theme and appearance preference, then applies them to the
/// whole app. Kept separate from `JournalApp` so the `@AppStorage` reads live in
/// a `View`, where changes re-render the tree.
///
/// Also the root router: it blocks on loading until the first vault
/// availability decision is resolved, then restores the last known user class
/// immediately while the runtime still refreshes local storage and CloudKit in
/// the background.
private struct RootView: View {

  /// Top-level app routes derived from persisted bootstrap state and the vault runtime.
  private enum RootRoute: Equatable {
    /// The app is checking whether vault storage and CloudKit recovery are available.
    case loading

    /// The user has vault state or has completed onboarding and can enter the vault flow.
    case existingUser(ExistingUserRoute)

    /// No local or remote vault state exists and onboarding has not been completed.
    case newUser
  }

  /// Routes inside the existing-user vault flow.
  private enum ExistingUserRoute: Equatable {
    /// User chooses, creates, refreshes, or shares a vault.
    case vaultSelection

    /// User is composing into the currently selected vault.
    case creation
  }

  /// Launch-only gate for opening the persisted default vault.
  ///
  /// When a stored vault id exists, `RootView` keeps showing the launch loading
  /// surface until restore either opens that vault or proves it should be
  /// ignored. This prevents the vault picker from flashing before the composer.
  private enum LastSelectedVaultRestoreState: Equatable {
    /// The launch restore decision has not completed yet.
    case pending

    /// The launch restore decision finished, whether by opening a vault or
    /// falling back to normal routing.
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
  @State private var existingUserRoute: ExistingUserRoute = .vaultSelection
  @State private var lastSelectedVaultRestoreState: LastSelectedVaultRestoreState = .pending

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

        case .existingUser(.creation):
          CreationView(
            onChangeVault: {
              withAnimation(.smooth) {
                existingUserRoute = .vaultSelection
              }
            }
          )
          .transition(.opacity)

        case .existingUser(.vaultSelection):
          VaultSelectionView(
            onVaultSelected: {
              enterCreationWithSelectedVault(animated: true)
            }
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

    await restoreLastSelectedVaultIfPossible()
  }

  private var rootRoute: RootRoute {
    guard hasResolvedInitialVaultAvailability else { return .loading }
    if shouldWaitForLastSelectedVaultRestore { return .loading }

    if vaultRuntime.vaults.isEmpty == false || hasCompletedOnboarding {
      return .existingUser(existingUserRoute)
    }

    return .newUser
  }

  private var shouldWaitForLastSelectedVaultRestore: Bool {
    lastSelectedVaultID.isEmpty == false && lastSelectedVaultRestoreState == .pending
  }

  private func completeNewUserOnboarding() {
    withAnimation(.smooth) {
      hasCompletedOnboarding = true
      existingUserRoute = .vaultSelection
    }
  }

  private func enterCreationWithSelectedVault(animated: Bool) {
    guard let selectedVault = vaultRuntime.selectedVault,
          vaultRuntime.selectedVaultState == .active else {
      return
    }

    lastSelectedVaultRestoreState = .resolved
    lastSelectedVaultID = selectedVault.vaultID.uuidString

    guard animated else {
      existingUserRoute = .creation
      return
    }

    withAnimation(.smooth) {
      existingUserRoute = .creation
    }
  }

  private func restoreLastSelectedVaultIfPossible() async {
    defer { lastSelectedVaultRestoreState = .resolved }

    guard vaultRuntime.vaults.isEmpty == false,
          lastSelectedVaultID.isEmpty == false else {
      return
    }

    guard let vaultID = VaultID(uuidString: lastSelectedVaultID) else {
      lastSelectedVaultID = ""
      return
    }

    guard vaultRuntime.vaults.contains(where: { $0.vaultID == vaultID }) else {
      lastSelectedVaultID = ""
      return
    }

    await vaultRuntime.selectVault(vaultID)

    guard vaultRuntime.selectedVault?.vaultID == vaultID,
          vaultRuntime.selectedVaultState == .active else {
      lastSelectedVaultID = ""
      return
    }

    enterCreationWithSelectedVault(animated: false)
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
      withAnimation(.smooth) {
        hasCompletedOnboarding = true
        hasResolvedInitialVaultAvailability = true
        existingUserRoute = .vaultSelection
      }
    } catch {
      notificationCenter.post(.vaultInviteAcceptanceFailed)
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
