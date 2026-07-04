import CloudKit
import JournalVault
import MuColor
import SwiftUI
import UIKit

/// Entry screen for choosing the vault that will back the composer.
///
/// `CreationView` writes through `JournalVaultRuntime.selectedVault`, so this
/// screen is the product boundary that turns a catalog row into the active
/// `VaultInstance` before the user starts composing.
struct VaultSelectionView: View {

  private let onVaultSelected: @MainActor @Sendable () -> Void

  @Environment(JournalVaultRuntime.self) private var vaultRuntime

  @State private var selectingVaultID: VaultID?
  @State private var preparingShareVaultID: VaultID?
  @State private var cloudSharingPresentation: VaultCloudSharingPresentation?
  @State private var shareError: VaultShareErrorMessage?
  @State private var isVaultCreationPresented = false
  @State private var isSettingsPresented = false

  init(onVaultSelected: @escaping @MainActor @Sendable () -> Void) {
    self.onVaultSelected = onVaultSelected
  }

  var body: some View {
    NavigationStack {
      VaultSelectionContent(
        runtimeState: vaultRuntime.state,
        initialAvailabilityResolution: vaultRuntime.lastInitialAvailabilityResolution,
        vaults: vaultRuntime.vaults,
        selectedVaultID: vaultRuntime.selectedVault?.vaultID,
        selectedVaultState: vaultRuntime.selectedVaultState,
        selectingVaultID: selectingVaultID,
        preparingShareVaultID: preparingShareVaultID,
        onSelectVault: selectVault,
        onShareVault: shareVault,
        onCreateVault: { isVaultCreationPresented = true },
        onRefresh: refreshVaults
      )
      .navigationTitle("Choose Vault")
      .toolbarTitleDisplayMode(.large)
      .toolbar {
        ToolbarItemGroup(placement: .topBarTrailing) {
          Button {
            isVaultCreationPresented = true
          } label: {
            Image(systemName: "plus")
          }
          .accessibilityLabel("New Vault")
          .disabled(vaultRuntime.state != .ready || selectingVaultID != nil)

          Button {
            refreshVaults()
          } label: {
            Image(systemName: "arrow.clockwise")
          }
          .accessibilityLabel("Refresh Vaults")

          Button {
            isSettingsPresented = true
          } label: {
            Image(systemName: "gearshape")
          }
          .accessibilityLabel("Settings")
        }
      }
    }
    .sheet(isPresented: $isVaultCreationPresented) {
      VaultCreationSheet(
        onCreate: createVault,
        onCancel: { isVaultCreationPresented = false }
      )
    }
    .sheet(isPresented: $isSettingsPresented) {
      SettingsScreen()
    }
    .sheet(item: $cloudSharingPresentation) { presentation in
      VaultCloudSharingController(
        presentation: presentation,
        onDidSave: {
          _ = try? await vaultRuntime.prepareShare(for: presentation.vaultID)
        },
        onDidStopSharing: {
          await vaultRuntime.noteSharingStopped(for: presentation.vaultID)
        },
        onError: { error in
          shareError = VaultShareErrorMessage(message: error.localizedDescription)
        }
      )
    }
    .alert(item: $shareError) { error in
      Alert(
        title: Text("Could Not Share Vault"),
        message: Text(error.message),
        dismissButton: .default(Text("OK"))
      )
    }
  }

  private func selectVault(_ descriptor: VaultDescriptor) {
    guard selectingVaultID == nil else { return }

    selectingVaultID = descriptor.vaultID

    Task { @MainActor in
      defer { selectingVaultID = nil }

      await vaultRuntime.selectVault(descriptor.vaultID)

      guard vaultRuntime.selectedVault?.vaultID == descriptor.vaultID,
            vaultRuntime.selectedVaultState == .active else {
        return
      }

      onVaultSelected()
    }
  }

  private func createVault(title: String) async -> String? {
    guard await vaultRuntime.createVault(title: title) != nil else {
      return vaultRuntime.lastMessage ?? "Could not create vault."
    }

    isVaultCreationPresented = false
    onVaultSelected()
    return nil
  }

  private func shareVault(_ descriptor: VaultDescriptor) {
    guard preparingShareVaultID == nil else { return }
    preparingShareVaultID = descriptor.vaultID

    Task { @MainActor in
      defer { preparingShareVaultID = nil }

      do {
        let preparation = try await vaultRuntime.prepareShare(for: descriptor.vaultID)
        cloudSharingPresentation = VaultCloudSharingPresentation(
          vaultID: descriptor.vaultID,
          title: descriptor.title,
          preparation: preparation
        )
      } catch {
        shareError = VaultShareErrorMessage(message: error.localizedDescription)
      }
    }
  }

  private func refreshVaults() {
    Task { @MainActor in
      await vaultRuntime.refresh()
    }
  }
}

private struct VaultSelectionContent: View {

  let runtimeState: JournalVaultRuntime.State
  let initialAvailabilityResolution: VaultInitialAvailabilityResolution?
  let vaults: [VaultDescriptor]
  let selectedVaultID: VaultID?
  let selectedVaultState: JournalVaultRuntime.SelectedVaultState
  let selectingVaultID: VaultID?
  let preparingShareVaultID: VaultID?
  let onSelectVault: @MainActor @Sendable (VaultDescriptor) -> Void
  let onShareVault: @MainActor @Sendable (VaultDescriptor) -> Void
  let onCreateVault: @MainActor @Sendable () -> Void
  let onRefresh: @MainActor @Sendable () -> Void

  var body: some View {
    switch runtimeState {
    case .starting:
      VaultSelectionLoadingView()
    case .ready:
      if vaults.isEmpty {
        VaultSelectionEmptyView(
          initialAvailabilityResolution: initialAvailabilityResolution,
          onCreateVault: onCreateVault,
          onRefresh: onRefresh
        )
      } else {
        VaultSelectionList(
          initialAvailabilityResolution: initialAvailabilityResolution,
          vaults: vaults,
          selectedVaultID: selectedVaultID,
          selectedVaultState: selectedVaultState,
          selectingVaultID: selectingVaultID,
          preparingShareVaultID: preparingShareVaultID,
          onSelectVault: onSelectVault,
          onShareVault: onShareVault
        )
      }
    case .failed(let message):
      VaultSelectionErrorView(message: message, onRefresh: onRefresh)
    }
  }
}

private struct VaultSelectionList: View {

  let initialAvailabilityResolution: VaultInitialAvailabilityResolution?
  let vaults: [VaultDescriptor]
  let selectedVaultID: VaultID?
  let selectedVaultState: JournalVaultRuntime.SelectedVaultState
  let selectingVaultID: VaultID?
  let preparingShareVaultID: VaultID?
  let onSelectVault: @MainActor @Sendable (VaultDescriptor) -> Void
  let onShareVault: @MainActor @Sendable (VaultDescriptor) -> Void

  var body: some View {
    List {
      if let initialAvailabilityResolution,
         initialAvailabilityResolution.isCloudKitDeferred {
        Section {
          VaultCloudKitDeferredBanner(resolution: initialAvailabilityResolution)
            .listRowBackground(Rectangle().fill(.appSecondaryContainer))
        }
      }

      Section {
        ForEach(vaults, id: \.vaultID) { vault in
          let isActive = selectedVaultID == vault.vaultID && selectedVaultState == .active
          let isSelecting = selectingVaultID == vault.vaultID
          let isPreparingShare = preparingShareVaultID == vault.vaultID

          VaultSelectionRow(
            title: vault.title,
            subtitle: vault.ownership.selectionSubtitle,
            systemImage: vault.ownership.selectionSystemImage,
            isActive: isActive,
            isSelecting: isSelecting,
            isPreparingShare: isPreparingShare,
            canShare: vault.ownership == .owned,
            onSelect: { onSelectVault(vault) },
            onShare: { onShareVault(vault) }
          )
          .disabled(selectingVaultID != nil || preparingShareVaultID != nil)
          .listRowBackground(Rectangle().fill(.appSecondaryContainer))
        }
      }
    }
    .listStyle(.insetGrouped)
    .scrollContentBackground(.hidden)
    .background(.background)
  }
}

private struct VaultSelectionRow: View {

  let title: String
  let subtitle: LocalizedStringResource
  let systemImage: String
  let isActive: Bool
  let isSelecting: Bool
  let isPreparingShare: Bool
  let canShare: Bool
  let onSelect: @MainActor @Sendable () -> Void
  let onShare: @MainActor @Sendable () -> Void

  var body: some View {
    HStack(spacing: 12) {
      Button(action: onSelect) {
        HStack(spacing: 12) {
          Image(systemName: systemImage)
            .font(.title3)
            .foregroundStyle(.tint)
            .frame(width: 30)

          VStack(alignment: .leading, spacing: 3) {
            Text(title)
              .font(.headline)
              .foregroundStyle(.appOnSecondaryContainer)
              .lineLimit(1)

            Text(subtitle)
              .font(.caption)
              .foregroundStyle(.appOnSecondaryContainer.opacity(0.62))
              .lineLimit(1)
          }

          Spacer(minLength: 0)

          if isSelecting {
            ProgressView()
              .controlSize(.small)
          } else if isActive {
            Image(systemName: "checkmark.circle.fill")
              .font(.title3)
              .foregroundStyle(.tint)
          } else {
            Image(systemName: "chevron.forward")
              .font(.caption.weight(.semibold))
              .foregroundStyle(.appOnSecondaryContainer.opacity(0.42))
          }
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      if canShare {
        Button(action: onShare) {
          ZStack {
            if isPreparingShare {
              ProgressView()
                .controlSize(.small)
            } else {
              Image(systemName: "person.crop.circle.badge.plus")
                .font(.title3)
            }
          }
          .frame(width: 36, height: 36)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Invite People")
      }
    }
    .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
  }
}

private struct VaultCloudSharingPresentation: Identifiable {
  let id = UUID()
  let vaultID: VaultID
  let title: String
  let preparation: VaultSharePreparation
}

private struct VaultShareErrorMessage: Identifiable {
  let id = UUID()
  let message: String
}

private struct VaultCloudSharingController: UIViewControllerRepresentable {

  let presentation: VaultCloudSharingPresentation
  let onDidSave: @MainActor @Sendable () async -> Void
  let onDidStopSharing: @MainActor @Sendable () async -> Void
  let onError: @MainActor @Sendable (any Error) -> Void

  func makeUIViewController(context: Context) -> UICloudSharingController {
    let controller = UICloudSharingController(
      share: presentation.preparation.share,
      container: presentation.preparation.container
    )
    controller.availablePermissions = [.allowPrivate, .allowReadWrite]
    controller.delegate = context.coordinator
    return controller
  }

  func updateUIViewController(_ controller: UICloudSharingController, context: Context) {}

  func makeCoordinator() -> Coordinator {
    Coordinator(
      title: presentation.title,
      onDidSave: onDidSave,
      onDidStopSharing: onDidStopSharing,
      onError: onError
    )
  }

  final class Coordinator: NSObject, UICloudSharingControllerDelegate {

    private let title: String
    private let onDidSave: @MainActor @Sendable () async -> Void
    private let onDidStopSharing: @MainActor @Sendable () async -> Void
    private let onError: @MainActor @Sendable (any Error) -> Void

    init(
      title: String,
      onDidSave: @escaping @MainActor @Sendable () async -> Void,
      onDidStopSharing: @escaping @MainActor @Sendable () async -> Void,
      onError: @escaping @MainActor @Sendable (any Error) -> Void
    ) {
      self.title = title
      self.onDidSave = onDidSave
      self.onDidStopSharing = onDidStopSharing
      self.onError = onError
    }

    func itemTitle(for cloudSharingController: UICloudSharingController) -> String? {
      title
    }

    func cloudSharingControllerDidSaveShare(_ cloudSharingController: UICloudSharingController) {
      Task { @MainActor in
        await onDidSave()
      }
    }

    func cloudSharingControllerDidStopSharing(_ cloudSharingController: UICloudSharingController) {
      Task { @MainActor in
        await onDidStopSharing()
      }
    }

    func cloudSharingController(
      _ cloudSharingController: UICloudSharingController,
      failedToSaveShareWithError error: any Error
    ) {
      Task { @MainActor in
        onError(error)
      }
    }
  }
}

/// Sheet that collects the user-facing title for a new local vault.
private struct VaultCreationSheet: View {

  let onCreate: @MainActor @Sendable (String) async -> String?
  let onCancel: @MainActor @Sendable () -> Void

  @FocusState private var isTitleFocused: Bool
  @State private var title = ""
  @State private var errorMessage: String?
  @State private var isCreating = false

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField("Vault Name", text: $title)
            .textContentType(.name)
            .textInputAutocapitalization(.words)
            .submitLabel(.done)
            .focused($isTitleFocused)
            .disabled(isCreating)
            .onSubmit { submit() }
        } footer: {
          if let errorMessage {
            Text(errorMessage)
              .foregroundStyle(.red)
          }
        }
      }
      .navigationTitle("New Vault")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            onCancel()
          }
          .disabled(isCreating)
        }

        ToolbarItem(placement: .confirmationAction) {
          Button {
            submit()
          } label: {
            if isCreating {
              ProgressView()
                .controlSize(.small)
            } else {
              Text("Create")
            }
          }
          .disabled(canSubmit == false)
        }
      }
    }
    .task { isTitleFocused = true }
    .interactiveDismissDisabled(isCreating)
  }

  private var trimmedTitle: String {
    title.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var canSubmit: Bool {
    trimmedTitle.isEmpty == false && isCreating == false
  }

  private func submit() {
    guard canSubmit else { return }

    let title = trimmedTitle
    isCreating = true
    errorMessage = nil

    Task { @MainActor in
      defer { isCreating = false }
      errorMessage = await onCreate(title)
    }
  }
}

private struct VaultSelectionLoadingView: View {

  var body: some View {
    VStack(spacing: 14) {
      ProgressView()
      Text("Preparing Vaults")
        .font(.headline)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.background)
  }
}

private struct VaultSelectionEmptyView: View {

  let initialAvailabilityResolution: VaultInitialAvailabilityResolution?
  let onCreateVault: @MainActor @Sendable () -> Void
  let onRefresh: @MainActor @Sendable () -> Void

  var body: some View {
    VStack(spacing: 18) {
      if let initialAvailabilityResolution,
         initialAvailabilityResolution.isCloudKitDeferred {
        VaultCloudKitDeferredBanner(resolution: initialAvailabilityResolution)
          .padding(.horizontal, 16)
      }

      ContentUnavailableView {
        Label("No Vaults", systemImage: "shippingbox")
      } actions: {
        Button {
          onCreateVault()
        } label: {
          Label("New Vault", systemImage: "plus")
        }

        Button {
          onRefresh()
        } label: {
          Label("Refresh", systemImage: "arrow.clockwise")
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.background)
  }
}

private struct VaultCloudKitDeferredBanner: View {

  let resolution: VaultInitialAvailabilityResolution

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: "icloud.slash")
        .font(.headline)
        .foregroundStyle(.secondary)
        .frame(width: 24)

      VStack(alignment: .leading, spacing: 4) {
        Text("iCloud Recovery Deferred")
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.primary)

        if let detail = resolution.displayDetail {
          Text(detail)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      Spacer(minLength: 0)
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
  }
}

private struct VaultSelectionErrorView: View {

  let message: String
  let onRefresh: @MainActor @Sendable () -> Void

  var body: some View {
    ContentUnavailableView {
      Label("Vaults Unavailable", systemImage: "exclamationmark.triangle")
    } description: {
      Text(message)
    } actions: {
      Button {
        onRefresh()
      } label: {
        Label("Retry", systemImage: "arrow.clockwise")
      }
    }
    .background(.background)
  }
}

private extension VaultOwnership {

  var selectionSubtitle: LocalizedStringResource {
    switch self {
    case .owned:
      "Owned by you"
    case .participant:
      "Shared with you"
    }
  }

  var selectionSystemImage: String {
    switch self {
    case .owned:
      "shippingbox"
    case .participant:
      "person.2"
    }
  }
}
