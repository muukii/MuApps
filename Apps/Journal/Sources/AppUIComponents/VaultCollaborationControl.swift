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
/// The saved zone-wide `CKShare` is registered on the `NSItemProvider`
/// synchronously — that registration is what makes `SWCollaborationView` treat
/// the vault as already collaborated, so its popover shows the current
/// participants and the manage action instead of the pre-share options UI.
/// Hosts therefore mount this control only once the share has been fetched, and
/// re-identify it (`viewIdentity`) when the share changes because the view
/// cannot swap its item provider after creation. Journal does not set
/// `activeParticipantCount` because the catalog tracks total participants, not
/// live presence.
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
  let share: CKShare
  let onShareUpdated: @MainActor @Sendable (VaultID) async -> Void
  let onSharingStopped: @MainActor @Sendable (VaultID) async -> Void
  let onError: @MainActor @Sendable (any Error) -> Void

  public init(
    vaultID: VaultID,
    title: String,
    share: CKShare,
    onShareUpdated: @escaping @MainActor @Sendable (VaultID) async -> Void,
    onSharingStopped: @escaping @MainActor @Sendable (VaultID) async -> Void,
    onError: @escaping @MainActor @Sendable (any Error) -> Void
  ) {
    self.vaultID = vaultID
    self.title = title
    self.share = share
    self.onShareUpdated = onShareUpdated
    self.onSharingStopped = onSharingStopped
    self.onError = onError
  }

  /// SwiftUI identity for one saved share state.
  ///
  /// `SWCollaborationView` reads its `NSItemProvider` only at creation, so
  /// hosts pass this to `.id(_:)` to rebuild the view when the share record
  /// itself changes (participants added, share re-created).
  public static func viewIdentity(vaultID: VaultID, share: CKShare) -> String {
    "\(vaultID.uuidString)-\(share.recordChangeTag ?? "")"
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

  public static func dismantleUIView(
    _ view: SWCollaborationView,
    coordinator: Coordinator
  ) {
    coordinator.dismantle(view)
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

  public static func dismantleNSView(
    _ view: SWCollaborationView,
    coordinator: Coordinator
  ) {
    coordinator.dismantle(view)
  }
  #endif

  public func makeCoordinator() -> Coordinator {
    Coordinator(
      vaultID: vaultID,
      title: title,
      onShareUpdated: onShareUpdated,
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

    itemProvider.registerCKShare(
      share,
      container: container,
      allowedSharingOptions: options
    )

    return itemProvider
  }

  private func configure(_ view: SWCollaborationView, context: Context) {
    context.coordinator.updateTitle(title, in: view)
    #if canImport(UIKit)
    view.accessibilityLabel = String(localized: "Manage Collaboration")
    view.cloudSharingControllerDelegate = context.coordinator
    #else
    view.setAccessibilityLabel(String(localized: "Manage Collaboration"))
    view.cloudSharingServiceDelegate = context.coordinator
    #endif
  }

  /// Bridges sharing callbacks and serialized collaboration-header updates.
  ///
  /// Explicit isolation keeps the UIKit and AppKit delegate conformances on
  /// the same UI-actor boundary even when their SDK annotations differ.
  @MainActor
  public final class Coordinator: NSObject, @MainActor VaultCollaborationSharingDelegate {

    private let vaultID: VaultID
    private var title: String
    private let onShareUpdated: @MainActor @Sendable (VaultID) async -> Void
    private let onSharingStopped: @MainActor @Sendable (VaultID) async -> Void
    private let onError: @MainActor @Sendable (any Error) -> Void
    private weak var headerTitleView: SWCollaborationView?
    private var appliedHeaderTitle: String?
    private var pendingHeaderTitle: String?
    private var headerTitleUpdateTask: Task<Void, Never>? {
      didSet {
        oldValue?.cancel()
      }
    }

    init(
      vaultID: VaultID,
      title: String,
      onShareUpdated: @escaping @MainActor @Sendable (VaultID) async -> Void,
      onSharingStopped: @escaping @MainActor @Sendable (VaultID) async -> Void,
      onError: @escaping @MainActor @Sendable (any Error) -> Void
    ) {
      self.vaultID = vaultID
      self.title = title
      self.onShareUpdated = onShareUpdated
      self.onSharingStopped = onSharingStopped
      self.onError = onError
    }

    /// Applies a changed header title after the active representable update.
    ///
    /// The system collaboration view forwards this setter into SwiftUI-backed
    /// state. Deferring the write prevents that internal publication from
    /// occurring while SwiftUI is updating the enclosing representable. The
    /// latest-title check prevents a queued stale rename from winning.
    func updateTitle(_ title: String, in view: SWCollaborationView) {
      if headerTitleView !== view {
        cancelPendingHeaderTitleUpdate()
        headerTitleView = view
        appliedHeaderTitle = nil
      }

      self.title = title

      guard appliedHeaderTitle != title else {
        cancelPendingHeaderTitleUpdate()
        return
      }
      guard pendingHeaderTitle != title else { return }

      let expectedTitle = title
      pendingHeaderTitle = expectedTitle
      headerTitleUpdateTask = Task { @MainActor [weak self, weak view] in
        await Task.yield()

        guard
          Task.isCancelled == false,
          let self,
          self.title == expectedTitle,
          self.pendingHeaderTitle == expectedTitle,
          let view,
          self.headerTitleView === view
        else {
          return
        }

        view.headerTitle = expectedTitle
        self.appliedHeaderTitle = expectedTitle
        self.pendingHeaderTitle = nil
      }
    }

    /// Ends title-update ownership when SwiftUI removes the represented view.
    func dismantle(_ view: SWCollaborationView) {
      guard headerTitleView === view else { return }

      cancelPendingHeaderTitleUpdate()
      headerTitleView = nil
      appliedHeaderTitle = nil
    }

    private func cancelPendingHeaderTitleUpdate() {
      headerTitleUpdateTask = nil
      pendingHeaderTitle = nil
    }

    #if canImport(UIKit)
    public func itemTitle(for cloudSharingController: UICloudSharingController) -> String? {
      title
    }

    public func cloudSharingControllerDidSaveShare(_ cloudSharingController: UICloudSharingController) {
      Task { @MainActor in
        await onShareUpdated(vaultID)
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
      let onShareUpdated = onShareUpdated
      let vaultID = vaultID
      Task { @MainActor [onShareUpdated, vaultID] in
        await onShareUpdated(vaultID)
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
