import CloudKit
import JournalVault
import SharedWithYou
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// SwiftUI bridge for the system collaboration control shown for a shared vault.
///
/// The control resolves the current zone-wide `CKShare` lazily through an
/// `NSItemProvider`, so mounting it in a row or toolbar does not perform
/// CloudKit transport work. Journal does not set `activeParticipantCount`
/// because the catalog tracks total participants, not live presence.
#if canImport(UIKit)
/// SwiftUI representable protocol used by the collaboration control on iOS.
public typealias VaultCollaborationViewRepresentable = UIViewRepresentable
/// System CloudKit sharing delegate used by the collaboration control on iOS.
public typealias VaultCollaborationSharingDelegate = UICloudSharingControllerDelegate
#else
/// SwiftUI representable protocol used by the collaboration control on macOS.
public typealias VaultCollaborationViewRepresentable = NSViewRepresentable
/// System CloudKit sharing delegate used by the collaboration control on macOS.
public typealias VaultCollaborationSharingDelegate = NSCloudSharingServiceDelegate
#endif

public struct VaultCollaborationControl: VaultCollaborationViewRepresentable {

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

  #if canImport(UIKit)
  public func makeUIView(context: Context) -> SWCollaborationView {
    let view = SWCollaborationView(itemProvider: makeItemProvider())
    configure(view, context: context)
    return view
  }

  public func updateUIView(_ view: SWCollaborationView, context: Context) {
    configure(view, context: context)
  }
  #else
  public func makeNSView(context: Context) -> SWCollaborationView {
    let view = SWCollaborationView(itemProvider: makeItemProvider())
    configure(view, context: context)
    return view
  }

  public func updateNSView(_ view: SWCollaborationView, context: Context) {
    configure(view, context: context)
  }
  #endif

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
    #if canImport(UIKit)
    view.accessibilityLabel = String(localized: "Manage Collaboration")
    view.cloudSharingControllerDelegate = context.coordinator
    #else
    view.setAccessibilityLabel(String(localized: "Manage Collaboration"))
    view.cloudSharingServiceDelegate = context.coordinator
    #endif
  }

  public final class Coordinator: NSObject, VaultCollaborationSharingDelegate {

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

    #if canImport(UIKit)
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
    #else
    public func sharingService(_ sharingService: NSSharingService, didSave share: CKShare) {
      let prepareShare = prepareShare
      let vaultID = vaultID
      let onError = onError
      Task { @MainActor [prepareShare, vaultID, onError] in
        do {
          _ = try await prepareShare(vaultID)
        } catch {
          onError(error)
        }
      }
    }

    public func sharingService(_ sharingService: NSSharingService, didStopSharing share: CKShare) {
      let onSharingStopped = onSharingStopped
      let vaultID = vaultID
      Task { @MainActor [onSharingStopped, vaultID] in
        await onSharingStopped(vaultID)
      }
    }

    public func sharingService(
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
    #endif
  }
}
