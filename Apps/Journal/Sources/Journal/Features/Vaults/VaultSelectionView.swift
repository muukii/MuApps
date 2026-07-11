import AppUIComponents
import CloudKit
import JournalVault
import MuColor
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
import SharedWithYou
#endif

/// Sheet content for choosing and managing the vault that backs the composer.
///
/// `CreationView` writes through `JournalVaultRuntime.selectedVault`, so this
/// view turns a catalog row into the active `VaultInstance`. The persistent
/// Journal Home remains underneath and swaps Creation identity only after the
/// new vault opens successfully.
struct VaultSelectionView: View {

  private let onVaultSelected: @MainActor @Sendable () -> Void
  private let onClose: @MainActor @Sendable () -> Void
  private let onActiveVaultChanged: @MainActor @Sendable () -> Void

  @Environment(JournalVaultRuntime.self) private var vaultRuntime

  @State private var selectingVaultID: VaultID?
  @State private var preparingShareVaultID: VaultID?
  @State private var renamingVaultID: VaultID?
  @State private var deletingVaultID: VaultID?
  @State private var cloudSharingPresentation: VaultCloudSharingPresentation?
  @State private var shareError: VaultShareErrorMessage?
  @State private var deletionConfirmation: VaultDeletionConfirmation?
  @State private var deletionError: VaultDeletionErrorMessage?
  @State private var renameEditorPresentation: VaultRenameEditorPresentation?
  @State private var iconEditorPresentation: VaultIconEditorPresentation?
  @State private var iconError: VaultIconErrorMessage?
  @State private var isVaultCreationPresented = false

  init(
    onVaultSelected: @escaping @MainActor @Sendable () -> Void,
    onClose: @escaping @MainActor @Sendable () -> Void,
    onActiveVaultChanged: @escaping @MainActor @Sendable () -> Void
  ) {
    self.onVaultSelected = onVaultSelected
    self.onClose = onClose
    self.onActiveVaultChanged = onActiveVaultChanged
  }

  var body: some View {
    NavigationStack {
      VaultSelectionContent(
        runtimeState: vaultRuntime.state,
        initialAvailabilityResolution: vaultRuntime.lastInitialAvailabilityResolution,
        vaults: vaultRuntime.vaults,
        selectedVaultID: vaultRuntime.selectedVault?.vaultID,
        selectingVaultID: selectingVaultID,
        preparingShareVaultID: preparingShareVaultID,
        renamingVaultID: renamingVaultID,
        deletingVaultID: deletingVaultID,
        onSelectVault: selectVault,
        onShareVault: shareVault,
        onPrepareCollaborationShare: prepareCollaborationShare,
        onCollaborationSharingStopped: noteCollaborationSharingStopped,
        onCollaborationError: presentShareError,
        onRenameVault: presentRenameEditor,
        onEditVaultIcon: presentIconEditor,
        onDeleteVault: requestDeleteVault,
        onCreateVault: { isVaultCreationPresented = true },
        onRefresh: refreshVaults
      )
      .navigationTitle("Vaults")
      .toolbarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done", action: onClose)
            .disabled(isVaultOperationInProgress)
        }

        ToolbarItem(placement: .primaryAction) {
          Button {
            isVaultCreationPresented = true
          } label: {
            Image(systemName: "plus")
          }
          .accessibilityLabel("New Vault")
          .disabled(vaultRuntime.state != .ready || isVaultOperationInProgress)
        }
      }
    }
    .sheet(isPresented: $isVaultCreationPresented) {
      VaultCreationSheet(
        onCreate: createVault,
        onCancel: { isVaultCreationPresented = false }
      )
    }
    .sheet(item: $renameEditorPresentation) { presentation in
      VaultRenameSheet(
        initialTitle: presentation.descriptor.title,
        onSave: { title in
          await renameVault(vaultID: presentation.descriptor.vaultID, title: title)
        },
        onCancel: { renameEditorPresentation = nil }
      )
    }
    .sheet(item: $iconEditorPresentation) { presentation in
      VaultIconEditorSheet(
        title: presentation.descriptor.title,
        initialIcon: presentation.descriptor.icon,
        onSave: { icon in
          updateVaultIcon(vaultID: presentation.descriptor.vaultID, icon: icon)
        },
        onCancel: { iconEditorPresentation = nil }
      )
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
    .alert(item: $deletionError) { error in
      Alert(
        title: Text("Could Not Delete Vault"),
        message: Text(error.message),
        dismissButton: .default(Text("OK"))
      )
    }
    .alert(item: $iconError) { error in
      Alert(
        title: Text("Could Not Update Icon"),
        message: Text(error.message),
        dismissButton: .default(Text("OK"))
      )
    }
    .confirmationDialog(
      deletionConfirmation?.title ?? String(localized: "Delete Vault?"),
      isPresented: deleteConfirmationBinding,
      titleVisibility: .visible,
      presenting: deletionConfirmation
    ) { confirmation in
      Button(confirmation.destructiveButtonTitle, role: .destructive) {
        deleteVault(confirmation.descriptor)
      }
      Button("Cancel", role: .cancel) {}
    } message: { confirmation in
      Text(confirmation.message)
    }
  }

  private var deleteConfirmationBinding: Binding<Bool> {
    Binding(
      get: { deletionConfirmation != nil },
      set: { isPresented in
        if isPresented == false {
          deletionConfirmation = nil
        }
      }
    )
  }

  private var isVaultOperationInProgress: Bool {
    selectingVaultID != nil
      || preparingShareVaultID != nil
      || renamingVaultID != nil
      || deletingVaultID != nil
  }

  private func selectVault(_ descriptor: VaultDescriptor) {
    guard selectingVaultID == nil, renamingVaultID == nil, deletingVaultID == nil else { return }

    if vaultRuntime.selectedVault?.vaultID == descriptor.vaultID,
       vaultRuntime.selectedVaultState == .active {
      onVaultSelected()
      return
    }

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

  private func createVault(title: String, icon: VaultIcon) async -> String? {
    guard await vaultRuntime.createVault(title: title, icon: icon) != nil else {
      return vaultRuntime.lastMessage ?? String(localized: "Could not create vault.")
    }

    isVaultCreationPresented = false
    onVaultSelected()
    return nil
  }

  private func shareVault(_ descriptor: VaultDescriptor) {
    guard preparingShareVaultID == nil, renamingVaultID == nil, deletingVaultID == nil else { return }
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

  private func prepareCollaborationShare(_ vaultID: VaultID) async throws -> VaultSharePreparation {
    try await vaultRuntime.prepareShare(for: vaultID)
  }

  private func noteCollaborationSharingStopped(_ vaultID: VaultID) async {
    await vaultRuntime.noteSharingStopped(for: vaultID)
  }

  private func presentShareError(_ error: any Error) {
    shareError = VaultShareErrorMessage(message: error.localizedDescription)
  }

  private func presentRenameEditor(_ descriptor: VaultDescriptor) {
    guard selectingVaultID == nil,
          preparingShareVaultID == nil,
          renamingVaultID == nil,
          deletingVaultID == nil else {
      return
    }
    renameEditorPresentation = VaultRenameEditorPresentation(descriptor: descriptor)
  }

  private func renameVault(vaultID: VaultID, title: String) async -> String? {
    guard renamingVaultID == nil else {
      return String(localized: "A vault update is already in progress.")
    }

    renamingVaultID = vaultID
    defer { renamingVaultID = nil }

    guard await vaultRuntime.renameVault(vaultID: vaultID, title: title) else {
      return vaultRuntime.lastMessage ?? String(localized: "Could not rename vault.")
    }

    renameEditorPresentation = nil
    return nil
  }

  private func presentIconEditor(_ descriptor: VaultDescriptor) {
    guard selectingVaultID == nil,
          preparingShareVaultID == nil,
          renamingVaultID == nil,
          deletingVaultID == nil else {
      return
    }
    iconEditorPresentation = VaultIconEditorPresentation(descriptor: descriptor)
  }

  private func updateVaultIcon(vaultID: VaultID, icon: VaultIcon) {
    Task { @MainActor in
      guard await vaultRuntime.updateVaultIcon(vaultID: vaultID, icon: icon) else {
        iconError = VaultIconErrorMessage(
          message: vaultRuntime.lastMessage ?? String(localized: "Could not update vault icon.")
        )
        return
      }
      iconEditorPresentation = nil
    }
  }

  private func requestDeleteVault(_ descriptor: VaultDescriptor) {
    guard renamingVaultID == nil, deletingVaultID == nil else { return }
    deletionConfirmation = VaultDeletionConfirmation(descriptor: descriptor)
  }

  private func deleteVault(_ descriptor: VaultDescriptor) {
    guard deletingVaultID == nil else { return }
    let isDeletingActiveVault = vaultRuntime.selectedVault?.vaultID == descriptor.vaultID
    deletingVaultID = descriptor.vaultID

    Task { @MainActor in
      defer { deletingVaultID = nil }

      guard await vaultRuntime.deleteVault(descriptor) else {
        deletionError = VaultDeletionErrorMessage(
          message: vaultRuntime.lastMessage ?? String(localized: "Could not delete vault.")
        )
        return
      }

      if isDeletingActiveVault {
        onActiveVaultChanged()
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
  let selectingVaultID: VaultID?
  let preparingShareVaultID: VaultID?
  let renamingVaultID: VaultID?
  let deletingVaultID: VaultID?
  let onSelectVault: @MainActor @Sendable (VaultDescriptor) -> Void
  let onShareVault: @MainActor @Sendable (VaultDescriptor) -> Void
  let onPrepareCollaborationShare: @MainActor @Sendable (VaultID) async throws -> VaultSharePreparation
  let onCollaborationSharingStopped: @MainActor @Sendable (VaultID) async -> Void
  let onCollaborationError: @MainActor @Sendable (any Error) -> Void
  let onRenameVault: @MainActor @Sendable (VaultDescriptor) -> Void
  let onEditVaultIcon: @MainActor @Sendable (VaultDescriptor) -> Void
  let onDeleteVault: @MainActor @Sendable (VaultDescriptor) -> Void
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
          selectingVaultID: selectingVaultID,
          preparingShareVaultID: preparingShareVaultID,
          renamingVaultID: renamingVaultID,
          deletingVaultID: deletingVaultID,
          onSelectVault: onSelectVault,
          onShareVault: onShareVault,
          onPrepareCollaborationShare: onPrepareCollaborationShare,
          onCollaborationSharingStopped: onCollaborationSharingStopped,
          onCollaborationError: onCollaborationError,
          onRenameVault: onRenameVault,
          onEditVaultIcon: onEditVaultIcon,
          onDeleteVault: onDeleteVault
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
  let selectingVaultID: VaultID?
  let preparingShareVaultID: VaultID?
  let renamingVaultID: VaultID?
  let deletingVaultID: VaultID?
  let onSelectVault: @MainActor @Sendable (VaultDescriptor) -> Void
  let onShareVault: @MainActor @Sendable (VaultDescriptor) -> Void
  let onPrepareCollaborationShare: @MainActor @Sendable (VaultID) async throws -> VaultSharePreparation
  let onCollaborationSharingStopped: @MainActor @Sendable (VaultID) async -> Void
  let onCollaborationError: @MainActor @Sendable (any Error) -> Void
  let onRenameVault: @MainActor @Sendable (VaultDescriptor) -> Void
  let onEditVaultIcon: @MainActor @Sendable (VaultDescriptor) -> Void
  let onDeleteVault: @MainActor @Sendable (VaultDescriptor) -> Void

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
          let isSelecting = selectingVaultID == vault.vaultID
          let isSelected = selectedVaultID == vault.vaultID
          let isPreparingShare = preparingShareVaultID == vault.vaultID
          let isRenaming = renamingVaultID == vault.vaultID
          let isDeleting = deletingVaultID == vault.vaultID

          VaultSelectionRow(
            vaultID: vault.vaultID,
            title: vault.title,
            subtitle: vault.ownership.selectionSubtitle,
            icon: vault.icon,
            isSelected: isSelected,
            isSelecting: isSelecting,
            isPreparingShare: isPreparingShare,
            isRenaming: isRenaming,
            isDeleting: isDeleting,
            isShared: vault.isShared,
            canShare: vault.ownership == .owned,
            onSelect: { onSelectVault(vault) },
            onShare: { onShareVault(vault) },
            onPrepareCollaborationShare: onPrepareCollaborationShare,
            onCollaborationSharingStopped: onCollaborationSharingStopped,
            onCollaborationError: onCollaborationError
          )
          .contextMenu {
            if vault.canRename {
              Button {
                onRenameVault(vault)
              } label: {
                Label("Rename", systemImage: "pencil")
              }
            }

            Button {
              onEditVaultIcon(vault)
            } label: {
              Label("Change Icon", systemImage: "face.smiling")
            }

            if vault.ownership == .owned {
              Button {
                onShareVault(vault)
              } label: {
                Label("Invite People", systemImage: "person.crop.circle.badge.plus")
              }
            }

            Button(role: .destructive) {
              onDeleteVault(vault)
            } label: {
              Label("Delete Vault", systemImage: "trash")
            }
          }
          .disabled(
            selectingVaultID != nil
              || preparingShareVaultID != nil
              || renamingVaultID != nil
              || deletingVaultID != nil
          )
          .listRowBackground(Rectangle().fill(.appSecondaryContainer))
        }
      }
    }
    .journalInsetGroupedListStyle()
    .scrollContentBackground(.hidden)
    .background(.background)
  }
}

private struct VaultSelectionRow: View {

  let vaultID: VaultID
  let title: String
  let subtitle: LocalizedStringResource
  let icon: VaultIcon
  let isSelected: Bool
  let isSelecting: Bool
  let isPreparingShare: Bool
  let isRenaming: Bool
  let isDeleting: Bool
  let isShared: Bool
  let canShare: Bool
  let onSelect: @MainActor @Sendable () -> Void
  let onShare: @MainActor @Sendable () -> Void
  let onPrepareCollaborationShare: @MainActor @Sendable (VaultID) async throws -> VaultSharePreparation
  let onCollaborationSharingStopped: @MainActor @Sendable (VaultID) async -> Void
  let onCollaborationError: @MainActor @Sendable (any Error) -> Void

  var body: some View {
    HStack(spacing: 12) {
      Button(action: onSelect) {
        HStack(spacing: 12) {
          VaultIconMark(icon: icon, size: 30, font: .title3)

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

          if isSelecting || isRenaming || isDeleting {
            ProgressView()
              .controlSize(.small)
          } else if isSelected {
            Image(systemName: "checkmark")
              .font(.body.weight(.semibold))
              .foregroundStyle(.tint)
              .accessibilityHidden(true)
          }
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityAddTraits(isSelected ? .isSelected : [])

      if canShare {
        HStack(spacing: 6) {
          if isShared {
            VaultCollaborationControl(
              vaultID: vaultID,
              title: title,
              prepareShare: onPrepareCollaborationShare,
              onSharingStopped: onCollaborationSharingStopped,
              onError: onCollaborationError
            )
            .id(vaultID)
            .frame(width: 36, height: 36)
          }

          VaultShareButton(
            isPreparing: isPreparingShare,
            onShare: onShare
          )
        }
        .fixedSize()
      }
    }
    .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
  }
}

#Preview("Vault Selection Cells") {
  VaultSelectionRowPreview()
}

private struct VaultSelectionRowPreview: View {

  private let baseVaultID = VaultID(rawValue: UUID(uuidString: "4AA2F163-22C7-41E1-8F92-289EA7EDB6C8")!)

  var body: some View {
    List {
      Section {
        previewRow(
          title: "Personal",
          subtitle: "Owned by you",
          icon: .emoji("📓"),
          isSelected: true
        )

        previewRow(
          title: "Shared Project Notes",
          subtitle: "Owned by you",
          icon: .systemImage("person.2"),
          isPreparingShare: true,
          canShare: true
        )

        previewRow(
          title: "Travel Archive",
          subtitle: "Owned by you",
          icon: .emoji("🌿"),
          isDeleting: true
        )

        previewRow(
          title: "Field Notes",
          subtitle: "Owned by you",
          icon: .systemImage("leaf"),
          isRenaming: true
        )

        previewRow(
          title: "Team Journal",
          subtitle: "Shared with you",
          icon: .systemImage("tray.full"),
          canShare: false
        )
      }
    }
    .journalInsetGroupedListStyle()
    .scrollContentBackground(.hidden)
    .background(.background)
  }

  private func previewRow(
    title: String,
    subtitle: LocalizedStringResource,
    icon: VaultIcon,
    isSelected: Bool = false,
    isSelecting: Bool = false,
    isPreparingShare: Bool = false,
    isRenaming: Bool = false,
    isDeleting: Bool = false,
    canShare: Bool = true
  ) -> some View {
    VaultSelectionRow(
      vaultID: baseVaultID,
      title: title,
      subtitle: subtitle,
      icon: icon,
      isSelected: isSelected,
      isSelecting: isSelecting,
      isPreparingShare: isPreparingShare,
      isRenaming: isRenaming,
      isDeleting: isDeleting,
      isShared: false,
      canShare: canShare,
      onSelect: {},
      onShare: {},
      onPrepareCollaborationShare: { _ in throw CancellationError() },
      onCollaborationSharingStopped: { _ in },
      onCollaborationError: { _ in }
    )
    .listRowBackground(Rectangle().fill(.appSecondaryContainer))
  }
}

/// Explicit vault invite button shown next to the system collaboration control.
private struct VaultShareButton: View {

  let isPreparing: Bool
  let onShare: @MainActor @Sendable () -> Void

  var body: some View {
    Button(action: onShare) {
      ZStack {
        if isPreparing {
          ProgressView()
            .controlSize(.small)
        } else {
          Image(systemName: "square.and.arrow.up")
            .font(.title3)
        }
      }
      .frame(width: 36, height: 36)
    }
    .buttonStyle(.borderless)
    .accessibilityLabel("Invite People")
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

private struct VaultDeletionErrorMessage: Identifiable {
  let id = UUID()
  let message: String
}

private struct VaultIconErrorMessage: Identifiable {
  let id = UUID()
  let message: String
}

private struct VaultRenameEditorPresentation: Identifiable {
  let descriptor: VaultDescriptor

  var id: VaultID { descriptor.vaultID }
}

private struct VaultIconEditorPresentation: Identifiable {
  let descriptor: VaultDescriptor

  var id: VaultID { descriptor.vaultID }
}

private struct VaultDeletionConfirmation: Identifiable {
  let descriptor: VaultDescriptor

  var id: VaultID { descriptor.vaultID }

  var title: String {
    switch descriptor.ownership {
    case .owned:
      String(localized: "Delete Vault?")
    case .participant:
      String(localized: "Remove Shared Vault?")
    }
  }

  var message: String {
    switch descriptor.ownership {
    case .owned:
      String(localized: "This deletes the vault from iCloud for everyone with access. Local cards and media on this device are removed too.")
    case .participant:
      String(localized: "This removes the shared vault from your iCloud account and this device. The owner's vault is not deleted.")
    }
  }

  var destructiveButtonTitle: String {
    switch descriptor.ownership {
    case .owned:
      String(localized: "Delete Vault")
    case .participant:
      String(localized: "Remove Shared Vault")
    }
  }
}

#if canImport(UIKit)
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
#elseif canImport(AppKit)
/// Native Mac host for the system CloudKit collaboration popover.
private struct VaultCloudSharingController: NSViewRepresentable {
  let presentation: VaultCloudSharingPresentation
  let onDidSave: @MainActor @Sendable () async -> Void
  let onDidStopSharing: @MainActor @Sendable () async -> Void
  let onError: @MainActor @Sendable (any Error) -> Void

  func makeNSView(context: Context) -> SWCollaborationView {
    let provider = NSItemProvider()
    provider.registerCKShare(
      presentation.preparation.share,
      container: presentation.preparation.container
    )
    let view = SWCollaborationView(itemProvider: provider)
    view.headerTitle = presentation.title
    view.cloudSharingServiceDelegate = context.coordinator
    return view
  }

  func updateNSView(_ view: SWCollaborationView, context: Context) {
    view.headerTitle = presentation.title
    view.cloudSharingServiceDelegate = context.coordinator
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(
      onDidSave: onDidSave,
      onDidStopSharing: onDidStopSharing,
      onError: onError
    )
  }

  final class Coordinator: NSObject, NSCloudSharingServiceDelegate {
    private let onDidSave: @MainActor @Sendable () async -> Void
    private let onDidStopSharing: @MainActor @Sendable () async -> Void
    private let onError: @MainActor @Sendable (any Error) -> Void

    init(
      onDidSave: @escaping @MainActor @Sendable () async -> Void,
      onDidStopSharing: @escaping @MainActor @Sendable () async -> Void,
      onError: @escaping @MainActor @Sendable (any Error) -> Void
    ) {
      self.onDidSave = onDidSave
      self.onDidStopSharing = onDidStopSharing
      self.onError = onError
    }

    func sharingService(_ sharingService: NSSharingService, didSave share: CKShare) {
      let onDidSave = onDidSave
      Task { @MainActor [onDidSave] in
        await onDidSave()
      }
    }

    func sharingService(_ sharingService: NSSharingService, didStopSharing share: CKShare) {
      let onDidStopSharing = onDidStopSharing
      Task { @MainActor [onDidStopSharing] in
        await onDidStopSharing()
      }
    }

    func sharingService(
      _ sharingService: NSSharingService,
      didCompleteForItems items: [Any],
      error: (any Error)?
    ) {
      guard let error else { return }
      let onError = onError
      Task { @MainActor [onError, error] in
        onError(error)
      }
    }
  }
}
#endif

/// Sheet that edits the user-facing title of an existing vault.
private struct VaultRenameSheet: View {

  let initialTitle: String
  let onSave: @MainActor @Sendable (String) async -> String?
  let onCancel: @MainActor @Sendable () -> Void

  @FocusState private var isTitleFocused: Bool
  @State private var title: String
  @State private var errorMessage: String?
  @State private var isSaving = false

  init(
    initialTitle: String,
    onSave: @escaping @MainActor @Sendable (String) async -> String?,
    onCancel: @escaping @MainActor @Sendable () -> Void
  ) {
    self.initialTitle = initialTitle
    self.onSave = onSave
    self.onCancel = onCancel
    _title = State(initialValue: initialTitle)
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField("Vault Name", text: $title)
            .textContentType(.name)
            #if os(iOS)
            .textInputAutocapitalization(.words)
            #endif
            .submitLabel(.done)
            .focused($isTitleFocused)
            .disabled(isSaving)
            .onSubmit { submit() }
        } footer: {
          if let errorMessage {
            Text(errorMessage)
              .foregroundStyle(.red)
          }
        }
      }
      .navigationTitle("Rename Vault")
      .journalInlineNavigationTitle()
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            onCancel()
          }
          .disabled(isSaving)
        }

        ToolbarItem(placement: .confirmationAction) {
          Button {
            submit()
          } label: {
            if isSaving {
              ProgressView()
                .controlSize(.small)
            } else {
              Text("Save")
            }
          }
          .disabled(canSubmit == false)
        }
      }
    }
    .task { isTitleFocused = true }
    .interactiveDismissDisabled(isSaving)
  }

  private var trimmedTitle: String {
    title.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var trimmedInitialTitle: String {
    initialTitle.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var canSubmit: Bool {
    trimmedTitle.isEmpty == false
      && trimmedTitle != trimmedInitialTitle
      && isSaving == false
  }

  private func submit() {
    guard canSubmit else { return }

    let title = trimmedTitle
    isSaving = true
    errorMessage = nil

    Task { @MainActor in
      defer { isSaving = false }
      errorMessage = await onSave(title)
    }
  }
}

/// Sheet that collects the user-facing title for a new local vault.
struct VaultCreationSheet: View {

  let onCreate: @MainActor @Sendable (String, VaultIcon) async -> String?
  let onCancel: @MainActor @Sendable () -> Void

  @FocusState private var isTitleFocused: Bool
  @State private var title = ""
  @State private var selectedIcon: VaultIcon = .default
  @State private var errorMessage: String?
  @State private var isCreating = false

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField("Vault Name", text: $title)
            .textContentType(.name)
            #if os(iOS)
            .textInputAutocapitalization(.words)
            #endif
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

        VaultIconPickerSection(selection: $selectedIcon)
      }
      .navigationTitle("New Vault")
      .journalInlineNavigationTitle()
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
      errorMessage = await onCreate(title, selectedIcon)
    }
  }
}

/// Sheet for changing a vault's catalog icon after it has been created.
private struct VaultIconEditorSheet: View {

  let title: String
  let initialIcon: VaultIcon
  let onSave: @MainActor @Sendable (VaultIcon) -> Void
  let onCancel: @MainActor @Sendable () -> Void

  @State private var selectedIcon: VaultIcon

  init(
    title: String,
    initialIcon: VaultIcon,
    onSave: @escaping @MainActor @Sendable (VaultIcon) -> Void,
    onCancel: @escaping @MainActor @Sendable () -> Void
  ) {
    self.title = title
    self.initialIcon = initialIcon
    self.onSave = onSave
    self.onCancel = onCancel
    _selectedIcon = State(initialValue: initialIcon)
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          HStack(spacing: 12) {
            VaultIconMark(icon: selectedIcon, size: 44, font: .title2)

            VStack(alignment: .leading, spacing: 3) {
              Text(title)
                .font(.headline)
                .lineLimit(1)

              Text("Vault Icon")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
          .padding(.vertical, 4)
        }

        VaultIconPickerSection(selection: $selectedIcon)
      }
      .navigationTitle("Vault Icon")
      .journalInlineNavigationTitle()
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            onCancel()
          }
        }

        ToolbarItem(placement: .confirmationAction) {
          Button("Save") {
            onSave(selectedIcon)
          }
          .disabled(selectedIcon == initialIcon)
        }
      }
    }
  }
}

/// Preset picker for the two supported vault icon families.
private struct VaultIconPickerSection: View {

  @Binding var selection: VaultIcon

  var body: some View {
    Section("Icon") {
      NavigationLink {
        VaultSystemImagePicker(selection: $selection)
      } label: {
        VaultIconFamilyNavigationLabel(
          family: .systemImage,
          selection: selection,
          title: "SF Symbols",
          systemImage: "square.grid.2x2"
        )
      }

      NavigationLink {
        VaultEmojiPicker(selection: $selection)
      } label: {
        VaultIconFamilyNavigationLabel(
          family: .emoji,
          selection: selection,
          title: "Emoji",
          systemImage: "face.smiling"
        )
      }
    }
  }
}

/// Compact form-row label that previews the current selection for one icon family.
private struct VaultIconFamilyNavigationLabel: View {

  let family: VaultIconFamily
  let selection: VaultIcon
  let title: LocalizedStringResource
  let systemImage: String

  var body: some View {
    HStack(spacing: 12) {
      Label {
        Text(title)
      } icon: {
        Image(systemName: systemImage)
      }

      Spacer(minLength: 8)

      if family.contains(selection) {
        VaultIconMark(icon: selection, size: 32, font: .body)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityValue(
      family.contains(selection)
        ? Text(selection.accessibilityLabel)
        : Text("")
    )
  }
}

/// Dedicated browser for the small curated SF Symbol collection.
private struct VaultSystemImagePicker: View {

  @Binding var selection: VaultIcon

  private let columns = [
    GridItem(.adaptive(minimum: 52), spacing: 12)
  ]

  var body: some View {
    ScrollView {
      LazyVGrid(columns: columns, spacing: 12) {
        ForEach(VaultIconPreset.systemImages, id: \.value) { icon in
          VaultIconOptionButton(
            icon: icon,
            isSelected: selection == icon,
            showsVariantIndicator: false,
            onSelect: { selection = icon }
          )
        }
      }
      .padding(16)
    }
    .navigationTitle("SF Symbols")
    .journalInlineNavigationTitle()
  }
}

/// Lazy, independently scrolling browser over the generated Unicode emoji catalog.
private struct VaultEmojiPicker: View {

  @Binding var selection: VaultIcon
  @State private var presentedFamily: VaultEmojiCatalog.Family?

  private let columns = [
    GridItem(.adaptive(minimum: 52), spacing: 12)
  ]

  var body: some View {
    ScrollView {
      LazyVGrid(columns: columns, spacing: 12) {
        ForEach(VaultEmojiCatalog.families) { family in
          let selectedEmoji = selection.emojiValue
          let displayedEmoji = family.displayValue(selectedEmoji: selectedEmoji)

          VaultIconOptionButton(
            icon: .emoji(displayedEmoji),
            isSelected: family.contains(selectedEmoji),
            showsVariantIndicator: family.hasSkinToneVariants,
            onSelect: {
              if family.hasSkinToneVariants {
                presentedFamily = family
              } else {
                selection = .emoji(family.baseValue)
              }
            }
          )
        }
      }
      .padding(16)
    }
    .navigationTitle("Emoji")
    .journalInlineNavigationTitle()
    .sheet(item: $presentedFamily) { family in
      VaultEmojiVariationPicker(
        family: family,
        selection: $selection
      )
      #if os(iOS)
      .presentationDetents([.medium])
      .presentationDragIndicator(.visible)
      #endif
    }
  }
}

/// Secondary palette for the fully-qualified skin-tone forms of one emoji.
private struct VaultEmojiVariationPicker: View {

  @Environment(\.dismiss) private var dismiss

  let family: VaultEmojiCatalog.Family
  @Binding var selection: VaultIcon

  private let columns = [
    GridItem(.adaptive(minimum: 52), spacing: 12)
  ]

  var body: some View {
    NavigationStack {
      ScrollView {
        LazyVGrid(columns: columns, spacing: 12) {
          ForEach(family.values, id: \.self) { value in
            let icon = VaultIcon.emoji(value)

            VaultIconOptionButton(
              icon: icon,
              isSelected: selection == icon,
              showsVariantIndicator: false,
              onSelect: {
                selection = icon
                dismiss()
              }
            )
          }
        }
        .padding(16)
      }
      .navigationTitle("Variations")
      .journalInlineNavigationTitle()
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            dismiss()
          }
        }
      }
    }
  }
}

/// One selectable icon cell shared by the dedicated symbol and emoji browsers.
private struct VaultIconOptionButton: View {

  let icon: VaultIcon
  let isSelected: Bool
  let showsVariantIndicator: Bool
  let onSelect: @MainActor @Sendable () -> Void

  var body: some View {
    Button(action: onSelect) {
      VaultIconMark(icon: icon, size: 48, font: .title3)
        .overlay {
          if isSelected {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .stroke(.tint, lineWidth: 2)
          }
        }
        .overlay(alignment: .bottomTrailing) {
          if showsVariantIndicator {
            Image(systemName: "ellipsis.circle.fill")
              .font(.caption2)
              .symbolRenderingMode(.palette)
              .foregroundStyle(.tint, .background)
              .offset(x: 3, y: 3)
              .accessibilityHidden(true)
          }
        }
    }
    .buttonStyle(.plain)
    .accessibilityLabel(icon.accessibilityLabel)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .accessibilityHint(
      showsVariantIndicator
        ? Text("Shows skin tone variations")
        : Text("")
    )
  }
}

private struct VaultIconMark: View {

  let icon: VaultIcon
  let size: CGFloat
  let font: Font

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(.tint.opacity(0.12))

      switch icon.kind {
      case .systemImage:
        Image(systemName: icon.value)
          .font(font)
          .foregroundStyle(.tint)
      case .emoji:
        Text(icon.value)
          .font(font)
      }
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }
}

private enum VaultIconFamily {

  case systemImage
  case emoji

  func contains(_ icon: VaultIcon) -> Bool {
    switch self {
    case .systemImage:
      switch icon.kind {
      case .systemImage:
        true
      case .emoji:
        false
      }
    case .emoji:
      switch icon.kind {
      case .systemImage:
        false
      case .emoji:
        true
      }
    }
  }
}

private enum VaultIconPreset {

  static let systemImages: [VaultIcon] = [
    .systemImage("shippingbox"),
    .systemImage("tray.full"),
    .systemImage("book.closed"),
    .systemImage("sparkles"),
    .systemImage("camera"),
    .systemImage("waveform"),
    .systemImage("paintpalette"),
    .systemImage("leaf"),
    .systemImage("heart"),
    .systemImage("moon.stars"),
    .systemImage("person.2"),
    .systemImage("lock"),
  ]
}

private extension VaultIcon {

  var emojiValue: String? {
    switch kind {
    case .systemImage:
      nil
    case .emoji:
      value
    }
  }

  var accessibilityLabel: String {
    switch kind {
    case .systemImage:
      String(localized: "SF Symbol \(value)")
    case .emoji:
      String(localized: "Emoji \(value)")
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

struct VaultCloudKitDeferredBanner: View {

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

private extension VaultDescriptor {

  var canRename: Bool {
    permission != .readOnly
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
