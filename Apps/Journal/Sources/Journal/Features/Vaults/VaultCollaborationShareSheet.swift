import CloudKit
import Foundation
import JournalVault
import SwiftUI

#if canImport(UIKit)
  import LinkPresentation
  import SharedWithYou
  import UIKit
#elseif canImport(AppKit)
  import AppKit
  import SharedWithYou
#endif

/// Saved vault-share data presented through the platform collaboration share UI.
///
/// The share is already durable when this value is created. The UI layer only
/// registers it on an `NSItemProvider`; it neither creates nor saves CloudKit
/// records, preserving `JournalVaultRuntime` as the sync boundary.
struct VaultCollaborationSharePresentation: Identifiable {
  /// Stable identity shared with the app-lifetime observer session.
  let id: UUID

  /// Vault whose zone-wide share is exposed to the system sharing service.
  let vaultID: VaultID

  /// User-facing title used in the collaboration preview.
  let title: String

  /// Saved CloudKit share and its owning container.
  let preparation: VaultSharePreparation
}

/// Presents an initial owner invite with the documented collaboration payload.
///
/// iOS uses `UIActivityItemsConfiguration` so Messages and compatible share
/// services receive a saved `CKShare`. Native macOS uses an
/// `NSSharingServicePicker` with an `NSPreviewRepresentingActivityItem`. Once
/// a share is fetched, existing-share management remains the responsibility of
/// `VaultCollaborationControl`.
@MainActor
struct VaultCollaborationShareSheet: View {

  let presentation: VaultCollaborationSharePresentation
  let onActivityCompletion: @MainActor @Sendable (Bool) -> Void
  let onError: @MainActor @Sendable (any Error) -> Void

  var body: some View {
    #if canImport(UIKit)
      VaultCollaborationActivityController(
        presentation: presentation,
        onActivityCompletion: onActivityCompletion,
        onError: onError
      )
      .ignoresSafeArea()
    #elseif canImport(AppKit)
      VaultCollaborationSharingPicker(
        presentation: presentation,
        onActivityCompletion: onActivityCompletion,
        onError: onError
      )
      .frame(width: 360, height: 148)
    #endif
  }
}

private func makeVaultShareItemProvider(
  presentation: VaultCollaborationSharePresentation
) -> NSItemProvider {
  let itemProvider = NSItemProvider()
  let options = CKAllowedSharingOptions(
    allowedParticipantPermissionOptions: .readWrite,
    allowedParticipantAccessOptions: .specifiedRecipientsOnly
  )
  itemProvider.registerCKShare(
    presentation.preparation.share,
    container: presentation.preparation.container,
    allowedSharingOptions: options
  )
  return itemProvider
}

#if canImport(UIKit)
  /// UIKit host for a saved CloudKit collaboration item provider.
  @MainActor
  private struct VaultCollaborationActivityController: UIViewControllerRepresentable {

    let presentation: VaultCollaborationSharePresentation
    let onActivityCompletion: @MainActor @Sendable (Bool) -> Void
    let onError: @MainActor @Sendable (any Error) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
      let itemProvider = makeVaultShareItemProvider(presentation: presentation)
      let configuration = UIActivityItemsConfiguration(itemProviders: [itemProvider])
      configuration.perItemMetadataProvider = { _, key in
        guard key == .linkPresentationMetadata else { return nil }
        return makeLinkMetadata(title: presentation.title)
      }

      let controller = UIActivityViewController(activityItemsConfiguration: configuration)
      controller.completionWithItemsHandler = { _, completed, _, error in
        Task { @MainActor in
          if let error {
            onError(error)
          }
          onActivityCompletion(completed && error == nil)
        }
      }
      return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}

    private func makeLinkMetadata(title: String) -> LPLinkMetadata {
      let metadata = LPLinkMetadata()
      metadata.title = title

      if let image = UIImage(systemName: "person.2.fill") {
        let imageProvider = NSItemProvider(object: image)
        metadata.imageProvider = imageProvider
        metadata.iconProvider = imageProvider
      }

      return metadata
    }
  }
#elseif canImport(AppKit)
  /// AppKit host that opens its picker from a user click, as required by
  /// `NSSharingServicePicker`'s mouse-down presentation contract.
  @MainActor
  private struct VaultCollaborationSharingPicker: NSViewRepresentable {

    let presentation: VaultCollaborationSharePresentation
    let onActivityCompletion: @MainActor @Sendable (Bool) -> Void
    let onError: @MainActor @Sendable (any Error) -> Void

    func makeNSView(context: Context) -> NSView {
      let button = NSButton(
        title: String(localized: "Share with People"),
        target: context.coordinator,
        action: #selector(Coordinator.showPicker(_:))
      )
      button.bezelStyle = .rounded
      button.setAccessibilityLabel(String(localized: "Invite People"))
      context.coordinator.configure(button: button)
      return button
    }

    func updateNSView(_ view: NSView, context: Context) {
      guard let button = view as? NSButton else { return }
      context.coordinator.configure(button: button)
    }

    func makeCoordinator() -> Coordinator {
      Coordinator(
        presentation: presentation,
        onActivityCompletion: onActivityCompletion,
        onError: onError
      )
    }

    final class Coordinator: NSObject,
      NSSharingServicePickerDelegate,
      NSCloudSharingServiceDelegate
    {

      private let presentation: VaultCollaborationSharePresentation
      private let onActivityCompletion: @MainActor @Sendable (Bool) -> Void
      private let onError: @MainActor @Sendable (any Error) -> Void
      private var picker: NSSharingServicePicker?
      private var didChooseSharingService = false

      init(
        presentation: VaultCollaborationSharePresentation,
        onActivityCompletion: @escaping @MainActor @Sendable (Bool) -> Void,
        onError: @escaping @MainActor @Sendable (any Error) -> Void
      ) {
        self.presentation = presentation
        self.onActivityCompletion = onActivityCompletion
        self.onError = onError
      }

      @MainActor
      func configure(button: NSButton) {
        button.title = String(localized: "Share with People")
      }

      @MainActor @objc func showPicker(_ sender: NSButton) {
        let itemProvider = makeVaultShareItemProvider(presentation: presentation)
        let image = NSImage(systemSymbolName: "person.2.fill", accessibilityDescription: nil)
        let preview = NSPreviewRepresentingActivityItem(
          item: itemProvider,
          title: presentation.title,
          image: image,
          icon: image
        )
        let picker = NSSharingServicePicker(items: [preview])
        picker.delegate = self
        self.picker = picker
        didChooseSharingService = false
        picker.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
      }

      func sharingServicePicker(
        _ sharingServicePicker: NSSharingServicePicker,
        delegateFor sharingService: NSSharingService
      ) -> (any NSSharingServiceDelegate)? {
        self
      }

      func sharingServicePicker(
        _ sharingServicePicker: NSSharingServicePicker,
        didChoose sharingService: NSSharingService?
      ) {
        didChooseSharingService = sharingService != nil
        guard sharingService == nil else { return }
        notifyActivityCompletion(false)
        picker = nil
      }

      func sharingService(_ sharingService: NSSharingService, didSave share: CKShare) {
        // The app-lifetime `CKSystemSharingUIObserver` owns durable refresh and
        // primer eligibility. This delegate remains only as immediate UI feedback.
      }

      func sharingService(_ sharingService: NSSharingService, didStopSharing share: CKShare) {
        // The app-lifetime `CKSystemSharingUIObserver` owns durable stop handling.
      }

      func sharingService(
        _ sharingService: NSSharingService,
        didCompleteForItems items: [Any],
        error: (any Error)?
      ) {
        if let error {
          notifyError(error)
          notifyActivityCompletion(false)
        } else {
          notifyActivityCompletion(didChooseSharingService)
        }
        picker = nil
      }

      private func notifyActivityCompletion(_ completed: Bool) {
        let onActivityCompletion = onActivityCompletion
        Task { @MainActor [onActivityCompletion, completed] in
          onActivityCompletion(completed)
        }
      }

      private func notifyError(_ error: any Error) {
        let onError = onError
        Task { @MainActor [onError, error] in
          onError(error)
        }
      }
    }
  }
#endif
