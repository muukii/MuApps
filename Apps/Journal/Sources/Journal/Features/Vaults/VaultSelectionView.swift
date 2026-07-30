import AppUIComponents
import CloudKit
import Foundation
import JournalVault
import MuColor
import Observation
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
        collaborationShares: vaultRuntime.collaborationShares,
        selectedVaultID: vaultRuntime.selectedVault?.vaultID,
        selectingVaultID: selectingVaultID,
        preparingShareVaultID: preparingShareVaultID,
        renamingVaultID: renamingVaultID,
        deletingVaultID: deletingVaultID,
        onSelectVault: selectVault,
        onShareVault: shareVault,
        onCollaborationShareUpdated: noteCollaborationShareUpdated,
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
    .task(id: sharedVaultIDs) {
      guard sharedVaultIDs.isEmpty == false else { return }
      await vaultRuntime.refreshCollaborationShares()
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

  /// Task identity for the collaboration-share refresh: re-fetch when the set
  /// of shared vaults changes (a vault became shared, or one was removed).
  private var sharedVaultIDs: [VaultID] {
    vaultRuntime.vaults.filter(\.isShared).map(\.vaultID)
  }

  private func selectVault(_ descriptor: VaultDescriptor) {
    guard selectingVaultID == nil, renamingVaultID == nil, deletingVaultID == nil else { return }

    if vaultRuntime.selectedVault?.vaultID == descriptor.vaultID,
      vaultRuntime.selectedVaultState == .active
    {
      onVaultSelected()
      return
    }

    selectingVaultID = descriptor.vaultID

    Task { @MainActor in
      defer { selectingVaultID = nil }

      await vaultRuntime.selectVault(descriptor.vaultID)

      guard vaultRuntime.selectedVault?.vaultID == descriptor.vaultID,
        vaultRuntime.selectedVaultState == .active
      else {
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
    guard preparingShareVaultID == nil, renamingVaultID == nil, deletingVaultID == nil else {
      return
    }
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

  private func noteCollaborationShareUpdated(_ vaultID: VaultID) async {
    await vaultRuntime.refreshCollaborationShares()
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
      deletingVaultID == nil
    else {
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
      deletingVaultID == nil
    else {
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
  let collaborationShares: [VaultID: CKShare]
  let selectedVaultID: VaultID?
  let selectingVaultID: VaultID?
  let preparingShareVaultID: VaultID?
  let renamingVaultID: VaultID?
  let deletingVaultID: VaultID?
  let onSelectVault: @MainActor @Sendable (VaultDescriptor) -> Void
  let onShareVault: @MainActor @Sendable (VaultDescriptor) -> Void
  let onCollaborationShareUpdated: @MainActor @Sendable (VaultID) async -> Void
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
          collaborationShares: collaborationShares,
          selectedVaultID: selectedVaultID,
          selectingVaultID: selectingVaultID,
          preparingShareVaultID: preparingShareVaultID,
          renamingVaultID: renamingVaultID,
          deletingVaultID: deletingVaultID,
          onSelectVault: onSelectVault,
          onShareVault: onShareVault,
          onCollaborationShareUpdated: onCollaborationShareUpdated,
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
  let collaborationShares: [VaultID: CKShare]
  let selectedVaultID: VaultID?
  let selectingVaultID: VaultID?
  let preparingShareVaultID: VaultID?
  let renamingVaultID: VaultID?
  let deletingVaultID: VaultID?
  let onSelectVault: @MainActor @Sendable (VaultDescriptor) -> Void
  let onShareVault: @MainActor @Sendable (VaultDescriptor) -> Void
  let onCollaborationShareUpdated: @MainActor @Sendable (VaultID) async -> Void
  let onCollaborationSharingStopped: @MainActor @Sendable (VaultID) async -> Void
  let onCollaborationError: @MainActor @Sendable (any Error) -> Void
  let onRenameVault: @MainActor @Sendable (VaultDescriptor) -> Void
  let onEditVaultIcon: @MainActor @Sendable (VaultDescriptor) -> Void
  let onDeleteVault: @MainActor @Sendable (VaultDescriptor) -> Void

  var body: some View {
    List {
      if let initialAvailabilityResolution,
        initialAvailabilityResolution.isCloudKitDeferred
      {
        Section {
          VaultCloudKitDeferredNotice(resolution: initialAvailabilityResolution)
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
            collaborationShare: vault.isShared ? collaborationShares[vault.vaultID] : nil,
            canShare: vault.ownership == .owned,
            onSelect: { onSelectVault(vault) },
            onShare: { onShareVault(vault) },
            onCollaborationShareUpdated: onCollaborationShareUpdated,
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
    .appInsetGroupedListStyle()
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
  /// Saved zone-wide share when the vault is shared and its share has been
  /// fetched; `nil` hides the collaboration control.
  let collaborationShare: CKShare?
  let canShare: Bool
  let onSelect: @MainActor @Sendable () -> Void
  let onShare: @MainActor @Sendable () -> Void
  let onCollaborationShareUpdated: @MainActor @Sendable (VaultID) async -> Void
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

      if canShare || collaborationShare != nil {
        HStack(spacing: 6) {
          if let collaborationShare {
            VaultCollaborationControl(
              vaultID: vaultID,
              title: title,
              share: collaborationShare,
              onShareUpdated: onCollaborationShareUpdated,
              onSharingStopped: onCollaborationSharingStopped,
              onError: onCollaborationError
            )
            .id(VaultCollaborationControl.viewIdentity(vaultID: vaultID, share: collaborationShare))
            .frame(width: 36, height: 36)
          }

          if canShare {
            VaultShareButton(
              isPreparing: isPreparingShare,
              onShare: onShare
            )
          }
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

  private let baseVaultID = VaultID(
    rawValue: UUID(uuidString: "4AA2F163-22C7-41E1-8F92-289EA7EDB6C8")!)

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
    .appInsetGroupedListStyle()
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
      collaborationShare: nil,
      canShare: canShare,
      onSelect: {},
      onShare: {},
      onCollaborationShareUpdated: { _ in },
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
      String(
        localized:
          "This deletes the vault from iCloud for everyone with access. Local entries and media on this device are removed too."
      )
    case .participant:
      String(
        localized:
          "This removes the shared vault from your iCloud account and this device. The owner's vault is not deleted."
      )
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

      func cloudSharingControllerDidStopSharing(_ cloudSharingController: UICloudSharingController)
      {
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
      .appInlineNavigationTitle()
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
      .appInlineNavigationTitle()
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
      .appInlineNavigationTitle()
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

/// Compact entry point for the unified SF Symbol and Emoji browser.
private struct VaultIconPickerSection: View {

  @Binding var selection: VaultIcon

  var body: some View {
    Section("Icon") {
      NavigationLink {
        VaultIconBrowser(selection: $selection)
      } label: {
        VaultIconSelectionNavigationLabel(selection: selection)
      }
    }
  }
}

/// Form-row label that keeps the current icon visible before opening the browser.
private struct VaultIconSelectionNavigationLabel: View {

  let selection: VaultIcon

  var body: some View {
    HStack(spacing: 12) {
      Label("Choose Icon", systemImage: "square.grid.2x2")

      Spacer(minLength: 8)

      VaultIconMark(icon: selection, size: 32, font: .body)
    }
    .accessibilityElement(children: .combine)
    .accessibilityValue(Text(selection.accessibilityLabel))
  }
}

/// Unified browser that searches curated SF Symbols and generated Emoji families.
private struct VaultIconBrowser: View {

  @Binding var selection: VaultIcon
  @State private var model = VaultIconSearchModel()
  @State private var presentedFamily: VaultEmojiCatalog.Family?

  var body: some View {
    @Bindable var model = model

    ZStack {
      if model.visibleItems.isEmpty {
        ContentUnavailableView.search(text: model.query)
      } else {
        VaultIconBrowserGrid(
          items: model.visibleItems,
          selection: $selection,
          onPresentEmojiVariations: { family in
            presentedFamily = family
          }
        )
      }
    }
    .navigationTitle("Icon")
    .appInlineNavigationTitle()
    .vaultIconSearch(text: $model.query)
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

/// Independently scrolling grid so the form never measures the full catalog.
private struct VaultIconBrowserGrid: View {

  let items: [VaultIconBrowserItem]
  @Binding var selection: VaultIcon
  let onPresentEmojiVariations: @MainActor @Sendable (VaultEmojiCatalog.Family) -> Void

  private let columns = [
    GridItem(.adaptive(minimum: 44), spacing: 8)
  ]

  var body: some View {
    ScrollView {
      LazyVGrid(columns: columns, spacing: 8) {
        ForEach(items) { item in
          VaultIconBrowserItemButton(
            item: item,
            selection: $selection,
            onPresentEmojiVariations: onPresentEmojiVariations
          )
        }
      }
      .padding(12)
    }
  }
}

/// Selection behavior for one heterogeneous item in the unified grid.
private struct VaultIconBrowserItemButton: View {

  let item: VaultIconBrowserItem
  @Binding var selection: VaultIcon
  let onPresentEmojiVariations: @MainActor @Sendable (VaultEmojiCatalog.Family) -> Void

  var body: some View {
    ZStack {
      switch item.content {
      case .systemImage(let preset):
        let icon = preset.icon
        VaultIconOptionButton(
          icon: icon,
          accessibilityLabel: String(localized: preset.accessibilityName),
          size: 44,
          isSelected: selection == icon,
          showsVariantIndicator: false,
          onSelect: { selection = icon }
        )
      case .emoji(let family):
        let selectedEmoji = selection.emojiValue
        let displayedEmoji = family.displayValue(selectedEmoji: selectedEmoji)
        VaultIconOptionButton(
          icon: .emoji(displayedEmoji),
          accessibilityLabel: VaultIcon.emoji(displayedEmoji).accessibilityLabel,
          size: 44,
          isSelected: family.contains(selectedEmoji),
          showsVariantIndicator: family.hasSkinToneVariants,
          onSelect: {
            if family.hasSkinToneVariants {
              onPresentEmojiVariations(family)
            } else {
              selection = .emoji(family.baseValue)
            }
          }
        )
      }
    }
  }
}

/// Secondary palette for the fully-qualified skin-tone forms of one emoji.
private struct VaultEmojiVariationPicker: View {

  @Environment(\.dismiss) private var dismiss

  let family: VaultEmojiCatalog.Family
  @Binding var selection: VaultIcon

  private let columns = [
    GridItem(.adaptive(minimum: 48), spacing: 8)
  ]

  var body: some View {
    NavigationStack {
      ScrollView {
        LazyVGrid(columns: columns, spacing: 8) {
          ForEach(family.values, id: \.self) { value in
            let icon = VaultIcon.emoji(value)

            VaultIconOptionButton(
              icon: icon,
              accessibilityLabel: icon.accessibilityLabel,
              size: 48,
              isSelected: selection == icon,
              showsVariantIndicator: false,
              onSelect: {
                selection = icon
                dismiss()
              }
            )
          }
        }
        .padding(12)
      }
      .navigationTitle("Variations")
      .appInlineNavigationTitle()
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

/// One selectable cell in the unified browser and variation palette.
private struct VaultIconOptionButton: View {

  let icon: VaultIcon
  let accessibilityLabel: String
  /// Logical cell size. Variation sheets use extra room because presentation scaling reduces it.
  let size: CGFloat
  let isSelected: Bool
  let showsVariantIndicator: Bool
  let onSelect: @MainActor @Sendable () -> Void

  var body: some View {
    Button(action: onSelect) {
      ZStack {
        Color.clear

        if isSelected {
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(.tint.opacity(0.12))
        }

        VaultIconGlyph(icon: icon, font: .title3)
      }
      .frame(width: size, height: size)
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
            .offset(x: 2, y: 2)
            .accessibilityHidden(true)
        }
      }
      .contentShape(Rectangle())
      .accessibilityElement(children: .ignore)
    }
    .buttonStyle(.plain)
    .frame(width: size, height: size)
    .contentShape(Rectangle())
    .accessibilityLabel(accessibilityLabel)
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

      VaultIconGlyph(icon: icon, font: font)
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }
}

/// Glyph-only rendering used where the browser should not add a cell surface.
private struct VaultIconGlyph: View {

  let icon: VaultIcon
  let font: Font

  var body: some View {
    ZStack {
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
  }
}

/// Picker-local state that recomputes a cached result list only when query changes.
@MainActor
@Observable
private final class VaultIconSearchModel {

  var query = "" {
    didSet {
      visibleItems = Self.filterItems(query: query)
    }
  }

  private(set) var visibleItems = VaultIconBrowserItem.all

  private static func filterItems(query: String) -> [VaultIconBrowserItem] {
    let tokens = VaultIconSearchNormalizer.tokens(from: query)
    guard tokens.isEmpty == false else {
      return VaultIconBrowserItem.all
    }

    return VaultIconBrowserItem.all
      .enumerated()
      .compactMap { offset, item -> (score: Int, offset: Int, item: VaultIconBrowserItem)? in
        let scores = tokens.compactMap { token in
          VaultIconSearchNormalizer.matchScore(
            queryToken: token,
            searchTerms: item.searchTerms
          )
        }
        guard scores.count == tokens.count else { return nil }
        return (scores.reduce(0, +), offset, item)
      }
      .sorted { lhs, rhs in
        if lhs.score == rhs.score {
          lhs.offset < rhs.offset
        } else {
          lhs.score < rhs.score
        }
      }
      .map(\.item)
  }
}

/// A heterogeneous, stably identified item displayed in the unified grid.
private struct VaultIconBrowserItem: Identifiable, Sendable {

  enum ID: Hashable, Sendable {
    case systemImage(String)
    case emoji(String)
  }

  enum Content: Sendable {
    case systemImage(VaultSystemImagePreset)
    case emoji(VaultEmojiCatalog.Family)
  }

  let id: ID
  let content: Content
  let searchTerms: [String]

  static let all: [VaultIconBrowserItem] = {
    let systemImages = VaultIconPreset.systemImages.map { preset in
      VaultIconBrowserItem(
        id: .systemImage(preset.name),
        content: .systemImage(preset),
        searchTerms: VaultIconSearchNormalizer.tokens(
          from: "\(preset.name) \(preset.searchTerms)"
        )
      )
    }
    let emojis = VaultEmojiCatalog.families.map { family in
      VaultIconBrowserItem(
        id: .emoji(family.id),
        content: .emoji(family),
        searchTerms: VaultIconSearchNormalizer.splitNormalized(family.searchTerms)
      )
    }
    return systemImages + emojis
  }()
}

/// A curated SF Symbol plus semantic terms for the same bilingual search field.
private struct VaultSystemImagePreset: Identifiable, Sendable {

  let name: String
  let accessibilityName: LocalizedStringResource
  let searchTerms: String

  var id: String { name }
  var icon: VaultIcon { .systemImage(name) }
}

private enum VaultIconSearchNormalizer {

  private static let locale = Locale(identifier: "en_US_POSIX")

  static func normalize(_ value: String) -> String {
    let folded = value.folding(
      options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
      locale: locale
    )
    let kanaNormalized =
      folded.applyingTransform(.hiraganaToKatakana, reverse: false)
      ?? folded
    return
      kanaNormalized
      .replacingOccurrences(of: ".", with: " ")
      .replacingOccurrences(of: "-", with: " ")
      .replacingOccurrences(of: "_", with: " ")
  }

  static func tokens(from query: String) -> [String] {
    splitNormalized(normalize(query))
  }

  static func splitNormalized(_ value: String) -> [String] {
    value
      .split(whereSeparator: { $0.isWhitespace })
      .map(String.init)
  }

  static func matchScore(queryToken: String, searchTerms: [String]) -> Int? {
    var bestScore: Int?
    let isLatinQuery = queryToken.unicodeScalars.contains { scalar in
      (0x30...0x39).contains(scalar.value)
        || (0x61...0x7A).contains(scalar.value)
    }

    for term in searchTerms {
      let score: Int?
      if term == queryToken {
        score = 0
      } else if term.hasPrefix(queryToken) {
        score = 1
      } else if isLatinQuery == false && term.hasSuffix(queryToken) {
        score = 2
      } else {
        score = nil
      }

      if let score, score < (bestScore ?? .max) {
        bestScore = score
      }
    }
    return bestScore
  }
}

private struct VaultIconSearchModifier: ViewModifier {

  @Binding var text: String

  func body(content: Content) -> some View {
    #if os(iOS)
      content.searchable(
        text: $text,
        placement: .navigationBarDrawer(displayMode: .always),
        prompt: "Search Icons"
      )
    #else
      content.searchable(text: $text, prompt: "Search Icons")
    #endif
  }
}

extension View {

  fileprivate func vaultIconSearch(text: Binding<String>) -> some View {
    modifier(VaultIconSearchModifier(text: text))
  }
}

private enum VaultIconPreset {

  static let systemImages: [VaultSystemImagePreset] = [
    .init(
      name: "shippingbox",
      accessibilityName: "Storage box",
      searchTerms: "shipping box package storage vault 箱 荷物 保管"
    ),
    .init(
      name: "tray.full",
      accessibilityName: "Inbox",
      searchTerms: "tray inbox archive storage トレイ 受信箱 保管"
    ),
    .init(
      name: "book.closed",
      accessibilityName: "Journal",
      searchTerms: "book journal diary notebook 本 日記 ノート"
    ),
    .init(
      name: "sparkles",
      accessibilityName: "Sparkles",
      searchTerms: "sparkles star magic shine きらきら 星 魔法"
    ),
    .init(
      name: "camera",
      accessibilityName: "Camera",
      searchTerms: "camera photo カメラ 写真"
    ),
    .init(
      name: "waveform",
      accessibilityName: "Audio",
      searchTerms: "waveform audio voice sound 波形 音声 録音"
    ),
    .init(
      name: "paintpalette",
      accessibilityName: "Art",
      searchTerms: "paint palette art color 絵 色 パレット"
    ),
    .init(
      name: "leaf",
      accessibilityName: "Nature",
      searchTerms: "leaf nature plant 葉 自然 植物"
    ),
    .init(
      name: "heart",
      accessibilityName: "Favorite",
      searchTerms: "heart love favorite ハート 愛 お気に入り"
    ),
    .init(
      name: "moon.stars",
      accessibilityName: "Night",
      searchTerms: "moon stars night 月 星 夜"
    ),
    .init(
      name: "person.2",
      accessibilityName: "People",
      searchTerms: "people person group shared 人 グループ 共有"
    ),
    .init(
      name: "lock",
      accessibilityName: "Private",
      searchTerms: "lock private security 鍵 ロック 非公開"
    ),
  ]
}

extension VaultIcon {

  fileprivate var emojiValue: String? {
    switch kind {
    case .systemImage:
      nil
    case .emoji:
      value
    }
  }

  fileprivate var accessibilityLabel: String {
    switch kind {
    case .systemImage:
      if let preset = VaultIconPreset.systemImages.first(where: { $0.name == value }) {
        return String(localized: preset.accessibilityName)
      }
      return String(localized: "SF Symbol \(value)")
    case .emoji:
      return String(localized: "Emoji \(value)")
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
        initialAvailabilityResolution.isCloudKitDeferred
      {
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

/// A standalone notice shown when launch can continue while iCloud recovery waits.
struct VaultCloudKitDeferredBanner: View {

  let resolution: VaultInitialAvailabilityResolution

  var body: some View {
    VaultCloudKitDeferredNotice(resolution: resolution)
      .background(
        .secondary.opacity(0.08),
        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
      )
  }
}

/// Surface-free deferred-recovery content for containers such as a `List` row.
struct VaultCloudKitDeferredNotice: View {

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
  }
}

#Preview("iCloud Recovery Deferred", traits: .sizeThatFitsLayout) {
  PrimaryContainer(accentColor: .default) {
    List {
      Section {
        VaultCloudKitDeferredNotice(
          resolution: .resolvedWithDeferredCloudKit(
            "iCloud account status is temporarily unavailable."
          )
        )
        .listRowBackground(Rectangle().fill(.appSecondaryContainer))
      }
    }
    .appInsetGroupedListStyle()
    .scrollContentBackground(.hidden)
    .background(.background)
  }
  .frame(width: 320, height: 140)
  .preferredColorScheme(.dark)
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

extension VaultDescriptor {

  fileprivate var canRename: Bool {
    permission != .readOnly
  }
}

extension VaultOwnership {

  fileprivate var selectionSubtitle: LocalizedStringResource {
    switch self {
    case .owned:
      "Owned by you"
    case .participant:
      "Shared with you"
    }
  }

  fileprivate var selectionSystemImage: String {
    switch self {
    case .owned:
      "shippingbox"
    case .participant:
      "person.2"
    }
  }
}
