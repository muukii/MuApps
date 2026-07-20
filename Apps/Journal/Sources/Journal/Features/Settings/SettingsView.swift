import JournalIntents
import JournalVault
import MuColor
import SwiftUI

#if DEBUG
  import MuHaptics
#endif

/// App-wide `UserDefaults` keys for Journal.
enum JournalDefaults {
  private static let cloudKitEnvironmentKeySuffix = VaultCloudKitEnvironment.current.rawValue

  private static func cloudKitScopedKey(_ baseKey: String) -> String {
    "\(baseKey).\(cloudKitEnvironmentKeySuffix)"
  }

  /// Selected key accent color id.
  ///
  /// The storage key intentionally retains its legacy spelling so existing
  /// theme choices can be mapped to the new accent-only model.
  static let accentColorID = "journal.theme.id"

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

  /// Last vault the user successfully opened from the vault picker.
  ///
  /// Stored as a `VaultID.uuidString` because this is a per-device presentation
  /// preference, not catalog data that should sync through `JournalVault`.
  /// Scoped by CloudKit environment because development and production catalogs
  /// live in separate local stores.
  static var lastSelectedVaultID: String {
    cloudKitScopedKey("journal.vault.lastSelected.id")
  }

  /// Whether the app has resolved its first vault availability decision.
  ///
  /// `RootView` uses this as a presentation cache only. The vault runtime still
  /// starts on every launch, but only the first install launch blocks while the
  /// app decides whether to recover iCloud vaults or continue from local-only state.
  /// Scoped by CloudKit environment so a Debug recovery decision cannot skip the
  /// Release/TestFlight production discovery pass.
  static var hasResolvedInitialVaultAvailability: String {
    cloudKitScopedKey("journal.vault.initialAvailability.resolved")
  }
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

  @AppStorage(JournalDefaults.accentColorID)
  private var accentColorID: String = AccentColor.default.id
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
        AccentColorSelectionView()
      } label: {
        HStack {
          Label("Accent Color", systemImage: "paintpalette")

          Spacer(minLength: 0)

          Text(AccentColor.with(id: accentColorID).name)
            .foregroundStyle(.secondary)
        }
      }
      .settingsListRowBackground()

      AppearanceSection(selectionID: $appearancePreferenceID)
      LocationSection(isEnabled: $shouldAttachLocationToNewCards)
      #if os(iOS)
        QuickCaptureVaultSection()
      #endif
      CloudStorageEstimateSection(runtime: vaultRuntime)
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
          JournalHelpView()
        } label: {
          Label("Help", systemImage: "questionmark.circle")
        }

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
    .appInlineNavigationTitle()
    .sensoryFeedback(.selection, trigger: appearancePreferenceID)
    .sensoryFeedback(.selection, trigger: shouldAttachLocationToNewCards)
    .appFullScreenCover(isPresented: $isShowingOnboarding) {
      OnboardingView(onComplete: { isShowingOnboarding = false })
    }
  }
}

// MARK: - Fileprivate Views

/// A form section for choosing whether Journal follows the device appearance or
/// requests a fixed Light/Dark scheme.
private struct AppearanceSection: View {

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
private struct WidgetInstructionsSection: View {

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
private struct LocationSection: View {

  @Binding var isEnabled: Bool

  var body: some View {
    Section {
      Toggle(isOn: $isEnabled) {
        Label("Attach Location", systemImage: "location")
      }
    } header: {
      Text("Location")
    } footer: {
      Text(
        "When enabled, new entries attach your current location automatically if iOS allows Tinycurve to access it."
      )
    }
    .settingsListRowBackground()
  }
}

/// A form section for the explicit destination shared by Action Button,
/// Shortcuts, App Intents, and the Share extension.
///
/// The choice lives in App Group preferences rather than standard app defaults
/// because each system entry point runs in a separate process. Journal never
/// substitutes the last-opened vault when this selection is missing or stale.
private struct QuickCaptureVaultSection: View {

  @State private var writableVaults: [JournalWritableVault] = []
  @State private var selectionID = ""
  @State private var didLoad = false
  @State private var statusMessage: String?

  var body: some View {
    Section {
      Picker("Quick Capture Vault", selection: $selectionID) {
        Text("Choose a Vault")
          .tag("")

        ForEach(writableVaults) { vault in
          Text(displayTitle(for: vault))
            .tag(vault.id.uuidString)
        }
      }
      .disabled(writableVaults.isEmpty)

      if writableVaults.isEmpty {
        Label("No writable vaults are available.", systemImage: "exclamationmark.triangle")
          .foregroundStyle(.secondary)
      }
    } header: {
      Text("Quick Capture")
    } footer: {
      if let statusMessage {
        Text(statusMessage)
      } else {
        Text(
          "Used by the Action Button, Shortcuts, and system sharing. Journal never chooses another vault automatically."
        )
      }
    }
    .settingsListRowBackground()
    .task { loadSelection() }
    .onChange(of: selectionID) { _, newValue in
      guard didLoad else { return }
      saveSelection(newValue)
    }
  }

  @MainActor
  private func loadSelection() {
    didLoad = false
    defer { didLoad = true }

    do {
      let service = JournalPostingService()
      writableVaults = try service.writableVaults()
      let storedID = try JournalQuickCapturePreferences().selectedVaultID()

      if let storedID,
        writableVaults.contains(where: { $0.id == storedID })
      {
        selectionID = storedID.uuidString
        statusMessage = nil
      } else {
        selectionID = ""
        statusMessage =
          storedID == nil
          ? nil
          : String(
            localized:
              "The previous Quick Capture Vault is no longer writable. Choose another vault.")
      }
    } catch {
      writableVaults = []
      selectionID = ""
      statusMessage = error.localizedDescription
    }
  }

  @MainActor
  private func saveSelection(_ id: String) {
    do {
      let vault = writableVaults.first { $0.id.uuidString == id }
      try JournalQuickCapturePreferences().setSelectedVault(vault)
      statusMessage =
        vault == nil
        ? String(localized: "Choose a vault before using Quick Capture.")
        : nil
    } catch {
      statusMessage = error.localizedDescription
    }
  }

  private func displayTitle(for vault: JournalWritableVault) -> String {
    let title = vault.title.trimmingCharacters(in: .whitespacesAndNewlines)
    return title.isEmpty ? String(localized: "Untitled Vault") : title
  }
}

/// A form section that opens Journal's local CloudKit storage estimate.
private struct CloudStorageEstimateSection: View {

  let runtime: JournalVaultRuntime

  @State private var estimate: JournalCloudStorageEstimate?

  var body: some View {
    Section {
      NavigationLink {
        CloudStorageEstimateView(runtime: runtime)
      } label: {
        HStack {
          Label("Cloud Storage", systemImage: "icloud")

          Spacer(minLength: 0)

          if let estimate {
            Text(estimate.ownedEstimatedPayloadBytes.storageByteCountText)
              .foregroundStyle(.secondary)
          }
        }
      }
    } header: {
      Text("Storage")
    } footer: {
      Text("Shows Journal's estimate for vault data stored through CloudKit.")
    }
    .settingsListRowBackground()
    .task {
      estimate = try? runtime.cloudStorageEstimate()
    }
  }
}

/// User-facing Settings screen for Journal-owned CloudKit payload estimates.
private struct CloudStorageEstimateView: View {

  let runtime: JournalVaultRuntime

  @State private var loadState = CloudStorageEstimateLoadState.loading

  var body: some View {
    Form {
      switch loadState {
      case .loading:
        CloudStorageEstimateLoadingSection()

      case .loaded(let estimate):
        CloudStorageEstimateSummarySection(estimate: estimate)
        CloudStorageEstimateBreakdownSection(estimate: estimate)
        CloudStorageEstimateVaultsSection(estimate: estimate)

      case .failed(let message):
        CloudStorageEstimateFailureSection(message: message)
      }
    }
    .scrollContentBackground(.hidden)
    .background(.background)
    .navigationTitle("Cloud Storage")
    .appInlineNavigationTitle()
    .toolbar {
      ToolbarItem(placement: .appTrailingAction) {
        Button {
          Task { await refresh() }
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        .accessibilityLabel("Refresh")
      }
    }
    .task {
      await refresh()
    }
  }

  @MainActor
  private func refresh() async {
    loadState = .loading
    await runtime.refresh()

    do {
      loadState = .loaded(try runtime.cloudStorageEstimate())
    } catch {
      loadState = .failed(error.localizedDescription)
    }
  }
}

/// Loading state for the Cloud Storage estimate screen.
private enum CloudStorageEstimateLoadState {
  case loading
  case loaded(JournalCloudStorageEstimate)
  case failed(String)
}

/// Initial loading section for the Cloud Storage estimate screen.
private struct CloudStorageEstimateLoadingSection: View {

  var body: some View {
    Section {
      HStack {
        ProgressView()
        Text("Calculating")
          .foregroundStyle(.secondary)
      }
    }
    .settingsListRowBackground()
  }
}

/// Error section shown when the local estimate cannot be read.
private struct CloudStorageEstimateFailureSection: View {

  let message: String

  var body: some View {
    Section {
      Label {
        Text(message)
      } icon: {
        Image(systemName: "exclamationmark.triangle")
          .foregroundStyle(.orange)
      }
    } header: {
      Text("Could Not Calculate")
    }
    .settingsListRowBackground()
  }
}

/// High-level totals for Journal's local CloudKit storage estimate.
private struct CloudStorageEstimateSummarySection: View {

  let estimate: JournalCloudStorageEstimate

  var body: some View {
    Section {
      LabeledContent(
        "Your iCloud Quota",
        value: estimate.ownedEstimatedPayloadBytes.storageByteCountText
      )

      if estimate.participantEstimatedPayloadBytes > 0 {
        LabeledContent(
          "Shared Vaults",
          value: estimate.participantEstimatedPayloadBytes.storageByteCountText
        )
      }

      LabeledContent("Records", value: estimate.recordCount.formatted())

      LabeledContent(
        "Updated",
        value: estimate.generatedAt.formatted(date: .omitted, time: .shortened)
      )
    } header: {
      Text("Estimate")
    } footer: {
      Text(
        "CloudKit does not expose exact iCloud usage to apps. This estimate uses Journal rows and attachment byte sizes, excluding CloudKit overhead and other apps."
      )
    }
    .settingsListRowBackground()
  }
}

/// App-wide byte totals grouped by payload category and attachment modality.
private struct CloudStorageEstimateBreakdownSection: View {

  let estimate: JournalCloudStorageEstimate

  var body: some View {
    Section {
      StorageBreakdownRow(
        title: "Text and Links",
        systemImage: "text.alignleft",
        detail: nil,
        byteSize: estimate.cardBodyBytes
      )

      StorageBreakdownRow(
        title: "Media Files",
        systemImage: "paperclip",
        detail: nil,
        byteSize: estimate.mediaBytes
      )

      StorageBreakdownRow(
        title: "Thumbnails",
        systemImage: "photo.on.rectangle",
        detail: nil,
        byteSize: estimate.thumbnailBytes
      )

      ForEach(estimate.mediaBreakdowns) { breakdown in
        StorageBreakdownRow(
          title: breakdown.kind.storageTitle,
          systemImage: breakdown.kind.storageSystemImage,
          detail: "\(breakdown.count.formatted()) attachments",
          byteSize: breakdown.byteSize
        )
      }
    } header: {
      Text("By Type")
    }
    .settingsListRowBackground()
  }
}

/// Per-vault navigation rows for storage estimate details.
private struct CloudStorageEstimateVaultsSection: View {

  let estimate: JournalCloudStorageEstimate

  var body: some View {
    Section {
      if estimate.vaults.isEmpty {
        Text("No vaults")
          .foregroundStyle(.secondary)
      } else {
        ForEach(estimate.vaults) { vaultEstimate in
          NavigationLink {
            VaultCloudStorageEstimateDetailView(vaultEstimate: vaultEstimate)
          } label: {
            VaultStorageEstimateRow(vaultEstimate: vaultEstimate)
          }
        }
      }
    } header: {
      Text("Vaults")
    }
    .settingsListRowBackground()
  }
}

/// Compact row for one vault's estimated payload.
private struct VaultStorageEstimateRow: View {

  let vaultEstimate: JournalVaultCloudStorageEstimate

  var body: some View {
    HStack(spacing: 12) {
      SettingsVaultIconMark(icon: vaultEstimate.descriptor.icon)

      VStack(alignment: .leading, spacing: 2) {
        Text(vaultEstimate.descriptor.storageDisplayTitle)
          .foregroundStyle(.primary)
        Text(vaultEstimate.descriptor.ownership.storageTitle)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Spacer(minLength: 0)

      Text(vaultEstimate.estimate.estimatedPayloadBytes.storageByteCountText)
        .foregroundStyle(.secondary)
    }
  }
}

private struct SettingsVaultIconMark: View {

  let icon: VaultIcon

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 7, style: .continuous)
        .fill(.tint.opacity(0.12))

      switch icon.kind {
      case .systemImage:
        Image(systemName: icon.value)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.tint)
      case .emoji:
        Text(icon.value)
          .font(.subheadline)
      }
    }
    .frame(width: 28, height: 28)
    .accessibilityHidden(true)
  }
}

/// Detail screen for one vault's CloudKit payload estimate.
private struct VaultCloudStorageEstimateDetailView: View {

  let vaultEstimate: JournalVaultCloudStorageEstimate

  var body: some View {
    Form {
      Section {
        LabeledContent(
          "Estimated Payload",
          value: vaultEstimate.estimate.estimatedPayloadBytes.storageByteCountText
        )
        LabeledContent("Records", value: vaultEstimate.estimate.recordCount.formatted())
        LabeledContent("Storage Owner") {
          Text(vaultEstimate.descriptor.ownership.storageTitle)
        }
      } header: {
        Text("Vault")
      } footer: {
        Text(vaultEstimate.descriptor.ownership.storageQuotaNote)
      }
      .settingsListRowBackground()

      Section {
        StorageBreakdownRow(
          title: "Text and Links",
          systemImage: "text.alignleft",
          detail: nil,
          byteSize: vaultEstimate.estimate.cardBodyBytes
        )
        StorageBreakdownRow(
          title: "Media Files",
          systemImage: "paperclip",
          detail: nil,
          byteSize: vaultEstimate.estimate.mediaBytes
        )
        StorageBreakdownRow(
          title: "Thumbnails",
          systemImage: "photo.on.rectangle",
          detail: nil,
          byteSize: vaultEstimate.estimate.thumbnailBytes
        )
      } header: {
        Text("By Type")
      }
      .settingsListRowBackground()

      Section {
        if vaultEstimate.estimate.mediaBreakdowns.isEmpty {
          Text("No media files")
            .foregroundStyle(.secondary)
        } else {
          ForEach(vaultEstimate.estimate.mediaBreakdowns) { breakdown in
            StorageBreakdownRow(
              title: breakdown.kind.storageTitle,
              systemImage: breakdown.kind.storageSystemImage,
              detail: "\(breakdown.count.formatted()) attachments",
              byteSize: breakdown.byteSize
            )
          }
        }
      } header: {
        Text("Media")
      }
      .settingsListRowBackground()
    }
    .scrollContentBackground(.hidden)
    .background(.background)
    .navigationTitle(vaultEstimate.descriptor.storageDisplayTitle)
    .appInlineNavigationTitle()
  }
}

/// Shared row style for a storage byte total.
private struct StorageBreakdownRow: View {

  let title: LocalizedStringResource
  let systemImage: String
  let detail: String?
  let byteSize: Int

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: systemImage)
        .foregroundStyle(.tint)
        .frame(width: 24)

      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .foregroundStyle(.primary)
        if let detail {
          Text(detail)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      Spacer(minLength: 0)

      Text(byteSize.storageByteCountText)
        .foregroundStyle(.secondary)
    }
  }
}

extension VaultDescriptor {

  /// User-facing title for Settings, with a fallback for remotely discovered
  /// vaults whose `VaultInfo` title has not arrived yet.
  fileprivate var storageDisplayTitle: String {
    title.isEmpty ? String(localized: "Untitled Vault") : title
  }
}

extension VaultOwnership {

  /// User-facing ownership label for storage surfaces.
  fileprivate var storageTitle: LocalizedStringResource {
    switch self {
    case .owned:
      "Owned by You"
    case .participant:
      "Shared with You"
    }
  }

  /// SF Symbol that communicates who owns the storage quota.
  fileprivate var storageSystemImage: String {
    switch self {
    case .owned:
      "icloud"
    case .participant:
      "person.2"
    }
  }

  /// Explains which iCloud account is charged for this vault's CloudKit data.
  fileprivate var storageQuotaNote: LocalizedStringResource {
    switch self {
    case .owned:
      "Owned vault records are stored in your private CloudKit database and count toward your iCloud storage."
    case .participant:
      "Shared vault records are visible to you, but CloudKit charges the originating owner's iCloud storage."
    }
  }
}

extension JournalVault.Attachment.Kind {

  /// User-facing modality label for storage breakdowns.
  fileprivate var storageTitle: LocalizedStringResource {
    switch self {
    case .photo:
      "Photos"
    case .video:
      "Videos"
    case .livePhoto:
      "Live Photos"
    case .file:
      "Files"
    case .audio:
      "Audio"
    case .suggestion:
      "Suggestions"
    case .doodle:
      "Doodles"
    case .bauhaus:
      "Bauhaus"
    case .unknown:
      "Unknown Media"
    }
  }

  /// SF Symbol for storage breakdown rows.
  fileprivate var storageSystemImage: String {
    switch self {
    case .photo:
      "photo"
    case .video:
      "video"
    case .livePhoto:
      "livephoto"
    case .file:
      "doc"
    case .audio:
      "waveform"
    case .suggestion:
      "sparkles"
    case .doodle:
      "pencil.line"
    case .bauhaus:
      "square.grid.3x3"
    case .unknown:
      "questionmark.square"
    }
  }
}

extension Int {

  /// Localized file-size string for storage totals.
  fileprivate var storageByteCountText: String {
    ByteCountFormatter.string(fromByteCount: Int64(self), countStyle: .file)
  }
}

extension View {

  /// Gives `Form` rows the same themed surface as Journal's custom list cells.
  ///
  /// SwiftUI's grouped `Form` row background does not inherit the app palette
  /// automatically, so each Settings row/section opts into the theme explicitly.
  fileprivate func settingsListRowBackground() -> some View {
    listRowBackground(Rectangle().fill(.appSecondaryContainer))
  }
}

#if DEBUG
  /// Compact Settings row for the target vault runtime.
  private struct VaultRuntimeSummaryRow: View {

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
  private struct VaultRuntimeDebugView: View {

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
            Label("Write Debug Entry", systemImage: "square.and.pencil")
          }
        } header: {
          Text("Actions")
        } footer: {
          Text(
            "Debug writes go through the selected vault instance and wake the configured sync engine."
          )
        }
        .settingsListRowBackground()
      }
      .scrollContentBackground(.hidden)
      .background(.background)
      .navigationTitle("Vault Runtime")
      .appInlineNavigationTitle()
      .task { await runtime.refresh() }
    }
  }

  extension VaultOwnership {

    /// Developer-facing ownership label for the vault runtime debug UI.
    fileprivate var displayTitle: String {
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
