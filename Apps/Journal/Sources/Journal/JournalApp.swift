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

  @AppStorage(JournalDefaults.themeID) private var themeID: String = Theme.default.id
  @AppStorage(JournalDefaults.appearancePreferenceID)
  private var appearancePreferenceID: String = JournalAppearancePreference.system.rawValue
  @AppStorage(JournalDefaults.hasCompletedOnboarding) private var hasCompletedOnboarding: Bool = false
  @AppStorage(JournalDefaults.hasResolvedInitialVaultAvailability)
  private var hasResolvedInitialVaultAvailability: Bool = false
  @State private var notificationCenter = JournalNotificationCenter()
  @State private var vaultRuntime: JournalVaultRuntime
  @State private var existingUserRoute: ExistingUserRoute = .vaultSelection

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
              withAnimation(.smooth) {
                existingUserRoute = .creation
              }
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

    withAnimation(.smooth) {
      if vaultRuntime.vaults.isEmpty == false {
        hasCompletedOnboarding = true
      }

      if resolution.isResolved {
        hasResolvedInitialVaultAvailability = true
      }
    }
  }

  private var rootRoute: RootRoute {
    guard hasResolvedInitialVaultAvailability else { return .loading }

    if vaultRuntime.vaults.isEmpty == false || hasCompletedOnboarding {
      return .existingUser(existingUserRoute)
    }

    return .newUser
  }

  private func completeNewUserOnboarding() {
    withAnimation(.smooth) {
      hasCompletedOnboarding = true
      existingUserRoute = .vaultSelection
    }
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
