#if DEBUG
import MuHaptics
#endif
import JournalVault
import MuColor
import SwiftUI

/// App-wide `UserDefaults` keys for Journal.
enum JournalDefaults {
  /// Selected color theme id. Resolved against `Theme.all` via `Theme.with(id:)`,
  /// falling back to `Theme.default` for unknown ids.
  static let themeID = "journal.theme.id"

  /// Selected appearance preference id. Resolved against
  /// `JournalAppearancePreference` before applying the scene color scheme.
  static let appearancePreferenceID = "journal.appearancePreference.id"

  /// Whether newly authored cards should automatically attach the current
  /// coordinate when system location permission allows it.
  static let shouldAttachLocationToNewCards = "journal.creation.attachLocation"

  /// Whether first-run onboarding has been completed.
  ///
  /// `RootView` uses this only after launch-time vault recovery has determined
  /// that no local or remote vaults exist. Existing vault state routes directly
  /// to the main vault flow, even after reinstall.
  static let hasCompletedOnboarding = "journal.onboarding.completed"

  /// Whether the app has resolved its first vault availability decision.
  ///
  /// `RootView` uses this as a presentation cache only. The vault runtime still
  /// starts on every launch, but only the first install launch blocks while the
  /// app decides whether to recover iCloud vaults or continue from local-only state.
  static let hasResolvedInitialVaultAvailability = "journal.vault.initialAvailability.resolved"
}

/// The user's app-wide appearance preference.
///
/// `.system` follows the device setting. `.light` and `.dark` request a concrete
/// SwiftUI `ColorScheme` for the whole Journal scene, including the active
/// `MuColor` palette resolution.
enum JournalAppearancePreference: String, CaseIterable, Identifiable, Sendable {
  case system
  case light
  case dark

  var id: String { rawValue }

  /// User-facing label for Settings.
  var title: LocalizedStringResource {
    switch self {
    case .system: "System"
    case .light: "Light"
    case .dark: "Dark"
    }
  }

  /// The color scheme requested from SwiftUI, or `nil` to follow the device.
  var colorScheme: ColorScheme? {
    switch self {
    case .system: nil
    case .light: .light
    case .dark: .dark
    }
  }

  /// Resolves a persisted raw value, falling back to `.system` for unknown ids.
  static func with(id: String) -> Self {
    Self(rawValue: id) ?? .system
  }
}

struct SettingsScreen: View {
  
  var body: some View {
    NavigationStack {
      SettingsView()
    }
  }
}

struct SettingsView: View {

  @Environment(JournalVaultRuntime.self) private var vaultRuntime

  @AppStorage(JournalDefaults.themeID) private var themeID: String = Theme.default.id
  @AppStorage(JournalDefaults.appearancePreferenceID)
  private var appearancePreferenceID: String = JournalAppearancePreference.system.rawValue
  @AppStorage(JournalDefaults.shouldAttachLocationToNewCards)
  private var shouldAttachLocationToNewCards: Bool = true

  /// Drives the manual re-showing of onboarding from this screen. Unlike the
  /// first-run path, this presents over the app and dismisses on completion —
  /// it never touches `hasCompletedOnboarding`.
  @State private var isShowingOnboarding = false

  var body: some View {
    Form {
      #if DEBUG
      Section {
        NavigationLink {
          VaultRuntimeDebugView(runtime: vaultRuntime)
        } label: {
          VaultRuntimeSummaryRow(runtime: vaultRuntime)
        }
      } header: {
        Text("Vault Runtime")
      } footer: {
        Text("Debug surface for the selected vault instance and explicit sync runtime.")
      }
      .settingsListRowBackground()
      #endif

      NavigationLink {
        ThemeSelectionView()
      } label: {
        HStack {
          Label("Theme", systemImage: "paintpalette")

          Spacer(minLength: 0)

          Text(Theme.with(id: themeID).name)
            .foregroundStyle(.secondary)
        }
      }
      .settingsListRowBackground()

      AppearanceSection(selectionID: $appearancePreferenceID)
      LocationSection(isEnabled: $shouldAttachLocationToNewCards)
      WidgetInstructionsSection()

      #if DEBUG
      Section("Lab") {
        NavigationLink {
          HapticEditorView()
        } label: {
          Label("Haptics", systemImage: "iphone.radiowaves.left.and.right")
        }

        NavigationLink {
          HapticTapSequencerView()
        } label: {
          Label("Haptic Doodle", systemImage: "hand.tap")
        }
      }
      .settingsListRowBackground()
      #endif

      Section("About") {
        NavigationLink {
          PrivacyPolicyView()
        } label: {
          Label("Privacy Policy", systemImage: "hand.raised")
        }

        Button {
          isShowingOnboarding = true
        } label: {
          Label("Show Onboarding", systemImage: "sparkles")
        }
      }
      .settingsListRowBackground()
    }
    .scrollContentBackground(.hidden)
    .background(.background)
    .navigationTitle("Settings")
    .navigationBarTitleDisplayMode(.inline)
    .sensoryFeedback(.selection, trigger: appearancePreferenceID)
    .sensoryFeedback(.selection, trigger: shouldAttachLocationToNewCards)
    .fullScreenCover(isPresented: $isShowingOnboarding) {
      OnboardingView(onComplete: { isShowingOnboarding = false })
    }
  }
}

// MARK: - Fileprivate Views

/// A form section for choosing whether Journal follows the device appearance or
/// requests a fixed Light/Dark scheme.
fileprivate struct AppearanceSection: View {

  @Binding var selectionID: String

  var body: some View {
    Section {
      Picker("Appearance", selection: $selectionID) {
        ForEach(JournalAppearancePreference.allCases) { preference in
          Text(preference.title)
            .tag(preference.rawValue)
        }
      }
      .pickerStyle(.segmented)
    } header: {
      Text("Appearance")
    } footer: {
      Text("System follows the device setting. Light and Dark override it for Journal.")
    }
    .settingsListRowBackground()
  }
}

/// A form section that links to the OS-level widget installation guide.
fileprivate struct WidgetInstructionsSection: View {

  var body: some View {
    Section {
      NavigationLink {
        WidgetInstructionsView()
      } label: {
        Label("Add Widgets", systemImage: "square.grid.2x2")
      }
    } header: {
      Text("Widgets")
    } footer: {
      Text("Instructions for adding Tinycurve to the Home Screen, Lock Screen, and StandBy.")
    }
    .settingsListRowBackground()
  }
}

/// A form section for the app-wide location attachment preference.
fileprivate struct LocationSection: View {

  @Binding var isEnabled: Bool

  var body: some View {
    Section {
      Toggle(isOn: $isEnabled) {
        Label("Attach Location", systemImage: "location")
      }
    } header: {
      Text("Location")
    } footer: {
      Text("When enabled, new cards attach your current location automatically if iOS allows Journal to access it.")
    }
    .settingsListRowBackground()
  }
}

fileprivate extension View {

  /// Gives `Form` rows the same themed surface as Journal's custom list cells.
  ///
  /// SwiftUI's grouped `Form` row background does not inherit the app palette
  /// automatically, so each Settings row/section opts into the theme explicitly.
  func settingsListRowBackground() -> some View {
    listRowBackground(Rectangle().fill(.appSecondaryContainer))
  }
}

#if DEBUG
/// Compact Settings row for the target vault runtime.
fileprivate struct VaultRuntimeSummaryRow: View {

  let runtime: JournalVaultRuntime

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: "shippingbox")
        .font(.title3)
        .foregroundStyle(iconStyle)
        .frame(width: 28)

      VStack(alignment: .leading, spacing: 2) {
        Text("Vault Runtime")
          .foregroundStyle(.primary)
        Text(detailText)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Spacer(minLength: 0)
    }
  }

  private var detailText: String {
    if let vault = runtime.selectedVault {
      return "\(vault.title) • \(runtime.selectedVaultState.displayTitle)"
    }
    return runtime.state.displayTitle
  }

  private var iconStyle: AnyShapeStyle {
    switch runtime.state {
    case .starting:
      AnyShapeStyle(.secondary)
    case .ready:
      AnyShapeStyle(.green)
    case .failed:
      AnyShapeStyle(.red)
    }
  }
}

/// Debug screen for checking that `JournalVault` is alive inside the app shell.
fileprivate struct VaultRuntimeDebugView: View {

  let runtime: JournalVaultRuntime

  var body: some View {
    Form {
      Section {
        LabeledContent("Runtime", value: runtime.state.displayTitle)
        if let detail = runtime.state.displayDetail {
          LabeledContent("Runtime Error", value: detail)
        }
        if let resolution = runtime.lastInitialAvailabilityResolution {
          LabeledContent("Initial Availability", value: resolution.displayTitle)
          if let detail = resolution.displayDetail {
            LabeledContent("Availability Detail", value: detail)
          }
        }
        LabeledContent("Selected Vault", value: runtime.selectedVaultState.displayTitle)
        if let detail = runtime.selectedVaultState.displayDetail {
          LabeledContent("Selected Vault Error", value: detail)
        }
        LabeledContent("Vault Count", value: runtime.vaults.count.formatted())
        if let pending = runtime.selectedVault?.pendingMutationCount {
          LabeledContent("Selected Outbox", value: pending.formatted())
        }
        if let lastRefreshedAt = runtime.lastRefreshedAt {
          LabeledContent(
            "Refreshed",
            value: lastRefreshedAt.formatted(date: .omitted, time: .standard)
          )
        }
        if let lastMessage = runtime.lastMessage {
          LabeledContent("Message", value: lastMessage)
        }
      } header: {
        Text("Status")
      }
      .settingsListRowBackground()

      Section {
        ForEach(runtime.vaults, id: \.vaultID) { vault in
          Button {
            Task { await runtime.selectVault(vault.vaultID) }
          } label: {
            HStack {
              VStack(alignment: .leading, spacing: 2) {
                Text(vault.title)
                  .foregroundStyle(.primary)
                Text(vault.ownership.displayTitle)
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }

              Spacer(minLength: 0)

              if runtime.selectedVault?.vaultID == vault.vaultID {
                Image(systemName: "checkmark")
                  .foregroundStyle(.tint)
              }
            }
          }
        }
      } header: {
        Text("Vaults")
      }
      .settingsListRowBackground()

      Section {
        Button {
          Task { await runtime.refresh() }
        } label: {
          Label("Refresh", systemImage: "arrow.clockwise")
        }

        Button {
          Task { await runtime.createDebugTextCard() }
        } label: {
          Label("Write Debug Card", systemImage: "square.and.pencil")
        }
      } header: {
        Text("Actions")
      } footer: {
        Text("Debug writes go through the selected vault instance and wake the configured sync engine.")
      }
      .settingsListRowBackground()
    }
    .scrollContentBackground(.hidden)
    .background(.background)
    .navigationTitle("Vault Runtime")
    .navigationBarTitleDisplayMode(.inline)
    .task { await runtime.refresh() }
  }
}

private extension VaultOwnership {

  /// Developer-facing ownership label for the vault runtime debug UI.
  var displayTitle: String {
    switch self {
    case .owned:
      "Owned"
    case .participant:
      "Participant"
    }
  }
}
#endif


// MARK: - Previews

#Preview {
  let vaultRuntime = JournalVaultRuntime.previewRuntime()
  NavigationStack {
    SettingsView()
  }
  .environment(vaultRuntime)
}
