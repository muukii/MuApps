import CloudKit
import JournalVault
import SharedWithYou
import SwiftUI
import UIKit

/// SwiftUI bridge for the system collaboration control shown for a shared vault.
///
/// The control resolves the current zone-wide `CKShare` lazily through an
/// `NSItemProvider`, so mounting it in a row or toolbar does not perform
/// CloudKit transport work. Journal does not set `activeParticipantCount`
/// because the catalog tracks total participants, not live presence.
public struct VaultCollaborationControl: UIViewRepresentable {

  let vaultID: VaultID
  let title: String
  let prepareShare: @MainActor @Sendable (VaultID) async throws -> VaultSharePreparation
  let onSharingStopped: @MainActor @Sendable (VaultID) async -> Void
  let onError: @MainActor @Sendable (any Error) -> Void

  public init(
    vaultID: VaultID,
    title: String,
    prepareShare: @escaping @MainActor @Sendable (VaultID) async throws -> VaultSharePreparation,
    onSharingStopped: @escaping @MainActor @Sendable (VaultID) async -> Void,
    onError: @escaping @MainActor @Sendable (any Error) -> Void
  ) {
    self.vaultID = vaultID
    self.title = title
    self.prepareShare = prepareShare
    self.onSharingStopped = onSharingStopped
    self.onError = onError
  }

  public func makeUIView(context: Context) -> SWCollaborationView {
    let view = SWCollaborationView(itemProvider: makeItemProvider())
    configure(view, context: context)
    return view
  }

  public func updateUIView(_ view: SWCollaborationView, context: Context) {
    configure(view, context: context)
  }

  public func makeCoordinator() -> Coordinator {
    Coordinator(
      vaultID: vaultID,
      title: title,
      prepareShare: prepareShare,
      onSharingStopped: onSharingStopped,
      onError: onError
    )
  }

  private func makeItemProvider() -> NSItemProvider {
    let itemProvider = NSItemProvider()
    let container = CKContainer(identifier: VaultCloudKitContainer.identifier)
    let options = CKAllowedSharingOptions(
      allowedParticipantPermissionOptions: .readWrite,
      allowedParticipantAccessOptions: .specifiedRecipientsOnly
    )
    let vaultID = vaultID
    let prepareShare = prepareShare

    itemProvider.registerCKShare(
      container: container,
      allowedSharingOptions: options
    ) {
      let preparation = try await prepareShare(vaultID)
      return preparation.share
    }

    return itemProvider
  }

  private func configure(_ view: SWCollaborationView, context: Context) {
    context.coordinator.title = title
    view.headerTitle = title
    view.accessibilityLabel = String(localized: "Manage Collaboration")
    view.cloudSharingControllerDelegate = context.coordinator
  }

  public final class Coordinator: NSObject, UICloudSharingControllerDelegate {

    private let vaultID: VaultID
    var title: String
    private let prepareShare: @MainActor @Sendable (VaultID) async throws -> VaultSharePreparation
    private let onSharingStopped: @MainActor @Sendable (VaultID) async -> Void
    private let onError: @MainActor @Sendable (any Error) -> Void

    init(
      vaultID: VaultID,
      title: String,
      prepareShare: @escaping @MainActor @Sendable (VaultID) async throws -> VaultSharePreparation,
      onSharingStopped: @escaping @MainActor @Sendable (VaultID) async -> Void,
      onError: @escaping @MainActor @Sendable (any Error) -> Void
    ) {
      self.vaultID = vaultID
      self.title = title
      self.prepareShare = prepareShare
      self.onSharingStopped = onSharingStopped
      self.onError = onError
    }

    public func itemTitle(for cloudSharingController: UICloudSharingController) -> String? {
      title
    }

    public func cloudSharingControllerDidSaveShare(_ cloudSharingController: UICloudSharingController) {
      Task { @MainActor in
        do {
          _ = try await prepareShare(vaultID)
        } catch {
          onError(error)
        }
      }
    }

    public func cloudSharingControllerDidStopSharing(_ cloudSharingController: UICloudSharingController) {
      Task { @MainActor in
        await onSharingStopped(vaultID)
      }
    }

    public func cloudSharingController(
      _ cloudSharingController: UICloudSharingController,
      failedToSaveShareWithError error: any Error
    ) {
      Task { @MainActor in
        onError(error)
      }
    }
  }
}
