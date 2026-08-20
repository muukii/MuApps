import AVFoundation
import AppUIComponents
import CaptureAudio
import CaptureBauhaus
import CaptureDoodle
import CapturePhoto
import CaptureSuggestions
import CloudKit
import CoreLocation
import CoreTransferable
import JournalIntents
import JournalVault
import MediaProcessing
import MuColor
import OSLog
import Photos
import PhotosUI
import ScrollEdgeEffect
import SwiftUI
import UniformTypeIdentifiers
import WidgetKit

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

private let photoLibraryImportLog = Logger(
  subsystem: "app.muukii.journal", category: "PhotoLibraryImport")

private let homeDropImportLog = Logger(
  subsystem: "app.muukii.journal", category: "HomeDropImport")

struct CreationView: View {

  @Binding private var systemCaptureRequest: JournalCaptureRequest?
  @Binding private var selectedHomeContentKind: JournalVault.Card.Kind?
  private let onChangeVault: (@MainActor @Sendable () -> Void)?
  private let onSelectVaultForSystemCapture: @MainActor @Sendable (VaultID) async -> Bool
  private let onSystemCaptureFailure: @MainActor @Sendable (String) -> Void

  @Environment(JournalNotificationCenter.self) private var notifications
  @Environment(JournalVaultRuntime.self) private var vaultRuntime

  init(
    systemCaptureRequest: Binding<JournalCaptureRequest?> = .constant(nil),
    selectedHomeContentKind: Binding<JournalVault.Card.Kind?> = .constant(nil),
    onChangeVault: (@MainActor @Sendable () -> Void)? = nil,
    onSelectVaultForSystemCapture: @escaping @MainActor @Sendable (VaultID) async -> Bool = { _ in
      false
    },
    onSystemCaptureFailure: @escaping @MainActor @Sendable (String) -> Void = { _ in }
  ) {
    _systemCaptureRequest = systemCaptureRequest
    _selectedHomeContentKind = selectedHomeContentKind
    self.onChangeVault = onChangeVault
    self.onSelectVaultForSystemCapture = onSelectVaultForSystemCapture
    self.onSystemCaptureFailure = onSystemCaptureFailure
  }

  @AppStorage(JournalDefaults.shouldAttachLocationToNewCards)
  private var shouldAttachLocationToNewCards: Bool = true

  @State private var composerState = CreationComposerState()
  @State private var composerDraftEditorPresentation: ComposerDraftEditorPresentation?
  @State private var linkEditorPresentation: LinkEditorPresentation?
  @State private var photoCapturePresentation: PhotoCapturePresentation?
  @State private var voiceRecorderPresentation: VoiceRecorderPresentation?
  @State private var quickDoodleCanvasPresentation: DoodleCanvasPresentation?
  @State private var quickBauhausGridPresentation: BauhausGridPresentation?
  @State private var quickDoodleSheetDetent: PresentationDetent = .large
  @State private var quickBauhausSheetDetent: PresentationDetent = .large
  @State private var navigationPath: [SavedListNavigationRoute] = []
  @State private var savedListScrollRequest: SavedListScrollRequest?
  #if os(iOS)
    @State private var isSettingsPresented: Bool = false
  #endif
  @State private var isChangeVaultConfirmationPresented = false
  @State private var isDiscardComposerDraftConfirmationPresented = false
  @State private var isSystemCaptureDiscardConfirmationPresented = false
  @State private var isSuggestionCapturePresented = false
  @State private var isImportingMediaFromLibrary: Bool = false
  @State private var selectedLibraryMediaItem: PhotosPickerItem?
  @State private var isLibraryMediaPickerPresented = false
  @State private var collaborationError: CollaborationErrorMessage?
  @Namespace private var namespace

  /// Shared one-shot location bridge. Each draft card stores the resolved
  /// coordinate it wants to persist; this object only handles permission and
  /// the current coordinate lookup.
  @State private var locationManager = LocationManager()

  /// Identity of the one coordinate lookup currently serving the composer.
  /// Text changes can arrive faster than Core Location, so they share this
  /// request instead of continuously superseding one another.
  @State private var locationRequestID: UUID?

  /// Drafts waiting for the shared in-flight coordinate, keyed by identity.
  ///
  /// An async media import can finish after another Reply is selected. Both
  /// drafts subscribe to the same one-shot fix without either becoming the
  /// other's location destination.
  @State private var locationRequestTargets: [ObjectIdentifier: CardEditDraft] = [:]

  /// Guards the compose surface while a save is in flight, so a card can't be
  /// created twice by a fast double-tap.
  @State private var isSaving: Bool = false

  /// Guards the Home drop importer while its independent root transactions are
  /// being committed. The authored composer draft remains separately owned.
  @State private var isPostingHomeDrop: Bool = false

  var body: some View {
    CreationContainer(
      draft: composerState.activeDraft,
      isPresented: navigationPath.isEmpty,
      placement: composerState.placement,
      replyTarget: composerState.replyTarget,
      isReplyTargetAvailable: composerState.isReplyTargetAvailable,
      isPostDestinationAvailable: activePostVault != nil,
      focusRequestID: composerState.focusRequestID,
      onConsumeFocusRequest: composerState.consumeFocusRequest,
      isProcessing: isSaving || isImportingMediaFromLibrary || isPostingHomeDrop,
      onOpenDraft: presentComposerDraftEditor,
      onDiscardDraft: requestComposerDraftDiscard,
      onToggleComposerMode: composerState.toggleActiveComposerMode,
      onPost: post,
      onCancelReply: {
        composerState.cancelReply()
      },
      onDropItems: postDroppedHomeItems
    ) {
      NavigationStack(path: $navigationPath) {
        SavedListView(
          selectedContentKind: $selectedHomeContentKind,
          replyTarget: composerState.replyTarget,
          scrollRequest: $savedListScrollRequest,
          onSelectReplyTarget: { target in
            composerState.selectReplyTarget(target)
          },
          onReplyTargetAvailabilityChange: { isAvailable in
            composerState.setReplyTargetAvailability(isAvailable)
          }
        )
        .toolbar(content: {
          if onChangeVault != nil {
            ToolbarItem(placement: .appLeadingAction) {
              Button {
                requestVaultChange()
              } label: {
                CreationVaultToolbarLabel(
                  title: vaultRuntime.selectedVault?.title ?? String(localized: "Vault"),
                  icon: vaultRuntime.selectedVault?.icon ?? .default
                )
              }
              .accessibilityLabel("Change Vault")
              .keyboardShortcut("v", modifiers: [.command, .shift])
            }
          }

          if let collaborationVault = selectedCollaborationVault,
            let collaborationShare = vaultRuntime.collaborationShares[collaborationVault.vaultID]
          {
            ToolbarItem(placement: .appTrailingAction) {
              VaultCollaborationControl(
                vaultID: collaborationVault.vaultID,
                title: collaborationVault.title,
                share: collaborationShare,
                onShareUpdated: noteCollaborationShareUpdated,
                onSharingStopped: noteCollaborationSharingStopped,
                onError: presentCollaborationError
              )
              .id(
                VaultCollaborationControl.viewIdentity(
                  vaultID: collaborationVault.vaultID,
                  share: collaborationShare
                )
              )
              .frame(width: 36, height: 36)
            }
          }

          ToolbarItem(placement: .appTrailingAction) {
            #if os(macOS)
              SettingsLink {
                Image(systemName: "gearshape")
              }
              .accessibilityLabel("Settings")
            #else
              Button(action: {
                isSettingsPresented.toggle()
              }) {
                Image(systemName: "gearshape")
              }
              .appMatchedTransitionSource(id: "settings", in: namespace)
              .keyboardShortcut(",", modifiers: .command)
            #endif
          }
        })
      }
    } menuContent: {
      CreationAddMenuContent(
        isSuggestionCaptureEnabled:
          JournalFeatureFlags.isJournalingSuggestionsCaptureEnabled,
        onComposeLink: presentLinkCapture,
        onCapturePhoto: presentPhotoCapture,
        onChooseMediaFromLibrary: presentLibraryMediaPicker,
        onDrawDoodle: presentDoodleCanvas,
        onComposeBauhaus: presentBauhausGrid,
        onRecordVoice: presentVoiceRecorder,
        onChooseSuggestion: finishSuggestionCapture
      )
    }
    .sheet(
      item: $composerDraftEditorPresentation,
      onDismiss: restoreEmptyComposerPlaceholderIfNeeded
    ) { presentation in
      NavigationStack {
        PostDraftEntryDetailEditor(
          draft: presentation.target,
          isSaving: isSaving
        )
      }
      .presentationDetents([.medium, .large])
      .presentationDragIndicator(.visible)
      .presentationBackground(.background)
    }
    .sheet(item: $linkEditorPresentation, onDismiss: restoreEmptyLinkPlaceholderIfNeeded) {
      presentation in
      PostDraftLinkEditorSheet(
        card: presentation.target
      )
      .presentationDetents([.medium, .large])
      .presentationDragIndicator(.visible)
      .presentationBackground(.background)
    }
    .sheet(item: $quickDoodleCanvasPresentation) { presentation in
      PostDraftDoodleCanvasSheet(
        card: presentation.target,
        onChange: { drawing in
          updateDoodle(drawing, presentation: presentation)
        }
      )
      .presentationDetents(
        [.medium, .large],
        selection: $quickDoodleSheetDetent
      )
      .presentationDragIndicator(.visible)
      .presentationBackground(.background)
    }
    .sheet(item: $quickBauhausGridPresentation) { presentation in
      PostDraftBauhausGridSheet(
        card: presentation.target,
        onChange: { document in
          updateBauhaus(document, presentation: presentation)
        }
      )
      .presentationDetents(
        [.medium, .large],
        selection: $quickBauhausSheetDetent
      )
      .presentationDragIndicator(.visible)
      .presentationBackground(.background)
    }
    .sheet(item: $photoCapturePresentation) { presentation in
      PostDraftPhotoCaptureSheet(
        card: presentation.target,
        onCapture: { photo in
          finishPhotoCapture(photo, target: presentation.target)
        }
      )
      .presentationDetents([.medium, .large])
      .presentationDragIndicator(.visible)
      .presentationBackground(.background)
    }
    .sheet(item: $voiceRecorderPresentation) { presentation in
      PostDraftVoiceRecorderSheet(
        card: presentation.target,
        onFinish: { recording in
          finishVoiceRecording(recording, target: presentation.target)
        }
      )
      .presentationDetents([.medium, .large])
      .presentationDragIndicator(.visible)
      .presentationBackground(.background)
    }
    #if os(iOS)
      .sheet(isPresented: $isSettingsPresented) {
        SettingsScreen()
        .appZoomNavigationTransition(sourceID: "settings", in: namespace)
        .presentationSizing(.form)
        .presentationBackground(.background)
      }
    #endif
    .confirmationDialog(
      "Discard Entry and Change Vault?",
      isPresented: $isChangeVaultConfirmationPresented,
      titleVisibility: .visible
    ) {
      Button("Discard and Change Vault", role: .destructive) {
        discardAllComposerDrafts()
        onChangeVault?()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("The current input has not been posted.")
    }
    .confirmationDialog(
      "Discard Entry?",
      isPresented: $isDiscardComposerDraftConfirmationPresented,
      titleVisibility: .visible
    ) {
      Button("Discard Entry", role: .destructive) {
        resetComposerDraft()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This entry has not been posted.")
    }
    .confirmationDialog(
      "Discard Entry and Start Quick Capture?",
      isPresented: $isSystemCaptureDiscardConfirmationPresented,
      titleVisibility: .visible
    ) {
      Button("Discard and Continue", role: .destructive) {
        discardAllComposerDrafts()
        Task { await continueSystemCaptureAfterDiscard() }
      }
      Button("Cancel", role: .cancel) {
        systemCaptureRequest = nil
      }
    } message: {
      Text("The current input has not been posted.")
    }
    .alert(item: $collaborationError) { error in
      Alert(
        title: Text("Could Not Manage Collaboration"),
        message: Text(error.message),
        dismissButton: .default(Text("OK"))
      )
    }
    .photosPicker(
      isPresented: $isLibraryMediaPickerPresented,
      selection: $selectedLibraryMediaItem,
      matching: .any(of: [.images, .livePhotos, .videos]),
      preferredItemEncoding: .current,
      photoLibrary: .shared()
    )
    .appNavigationBarStyle()
    .journalSuggestionCapturePresenter(
      isPresented: $isSuggestionCapturePresented,
      onCommit: finishSuggestionCapture
    )
    .task(id: systemCaptureRequest?.id) {
      await routeSystemCaptureRequestIfNeeded()
    }
    .task(id: selectedCollaborationVault?.vaultID) {
      // The toolbar collaboration control needs the live zone-wide share; this
      // also runs when a sync/catalog correction newly marks the vault shared.
      guard selectedCollaborationVault != nil else { return }
      await vaultRuntime.refreshCollaborationShares()
    }
    .onChange(of: selectedLibraryMediaItem) { _, item in
      guard let item else { return }
      selectedLibraryMediaItem = nil
      importMediaFromLibrary(item)
    }
    .onChange(of: shouldAttachLocationToNewCards) { _, isEnabled in
      if isEnabled {
        attachLocationToComposerDraftIfNeeded()
      } else {
        clearLocationFromComposerDraft()
      }
    }
    .onChange(of: composerDraft.text) { _, _ in
      updateComposerLocationForTextChange()
    }
    .onChange(of: locationManager.authorizationStatus) { _, status in
      // System access can be revoked after a coordinate was attached. Clear
      // draft coordinates so the UI never claims location metadata it can no
      // longer justify.
      switch status {
      case .denied, .restricted:
        clearLocationFromComposerDraft()
      case .authorizedWhenInUse, .authorizedAlways:
        attachLocationToComposerDraftIfNeeded()
      case .notDetermined:
        break
      @unknown default:
        break
      }
    }

  }

  /// Draft selected by the explicit root or Reply placement.
  ///
  /// Home owns the root draft; each selected parent owns a separate Reply draft.
  /// Map navigation has no effect on this ownership boundary.
  private var composerDraft: CardEditDraft {
    composerState.activeDraft
  }

  /// Selected vault that can safely accept the current root or Reply draft.
  ///
  /// The runtime may retain a `VaultInstance` while reopening or after a
  /// failure. Both the visible post affordance and `post()` use this boundary
  /// so a retained but inactive instance never accepts a write.
  private var activePostVault: VaultInstance? {
    guard vaultRuntime.selectedVaultState == .active,
      let vault = vaultRuntime.selectedVault,
      composerState.isActiveDestinationAvailable(in: vault.vaultID)
    else {
      return nil
    }
    return vault
  }

  private var selectedVaultDescriptor: VaultDescriptor? {
    guard let selectedVault = vaultRuntime.selectedVault else {
      return nil
    }

    return vaultRuntime.vaults.first { $0.vaultID == selectedVault.vaultID }
      ?? selectedVault.descriptor
  }

  private var selectedCollaborationVault: VaultDescriptor? {
    guard let descriptor = selectedVaultDescriptor,
      descriptor.isShared
    else {
      return nil
    }

    return descriptor
  }

  private func requestVaultChange() {
    guard let onChangeVault else { return }

    if composerState.hasAuthoredDrafts == false {
      onChangeVault()
    } else {
      isChangeVaultConfirmationPresented = true
    }
  }

  /// Routes one system request without silently replacing unpublished input.
  /// A cross-vault request remains bound while the parent swaps the active
  /// `CreationView`; the newly keyed view then presents the requested surface.
  private func routeSystemCaptureRequestIfNeeded() async {
    guard let request = systemCaptureRequest,
      let targetVaultID = request.vaultID
    else {
      return
    }

    if vaultRuntime.selectedVault?.vaultID != targetVaultID {
      guard composerState.hasAuthoredDrafts == false else {
        isSystemCaptureDiscardConfirmationPresented = true
        return
      }
      prepareHomeForSystemCapture()
      await selectVaultForSystemCapture(targetVaultID)
      return
    }

    guard composerState.hasAuthoredDrafts == false else {
      isSystemCaptureDiscardConfirmationPresented = true
      return
    }

    prepareHomeForSystemCapture()
    consumeAndPresentSystemCapture(request)
  }

  private func continueSystemCaptureAfterDiscard() async {
    guard let request = systemCaptureRequest,
      let targetVaultID = request.vaultID
    else {
      return
    }

    if vaultRuntime.selectedVault?.vaultID != targetVaultID {
      prepareHomeForSystemCapture()
      await selectVaultForSystemCapture(targetVaultID)
    } else {
      prepareHomeForSystemCapture()
      consumeAndPresentSystemCapture(request)
    }
  }

  /// System quick capture always authors a new root card.
  private func prepareHomeForSystemCapture() {
    navigationPath.removeAll(keepingCapacity: false)
    composerState.cancelReply(requestFocus: false)
    savedListScrollRequest = nil
  }

  private func selectVaultForSystemCapture(_ vaultID: VaultID) async {
    guard await onSelectVaultForSystemCapture(vaultID) else {
      systemCaptureRequest = nil
      onSystemCaptureFailure(
        String(
          localized: "The selected Vault could not be opened. Choose it again for this action."
        )
      )
      return
    }
    // Keep the request alive. `JournalHomeContent` keys CreationView by vault,
    // and the replacement view consumes it after the selection transition.
  }

  private func consumeAndPresentSystemCapture(_ request: JournalCaptureRequest) {
    systemCaptureRequest = nil

    switch request.mode {
    case .text:
      // An explicit system Text capture overrides an otherwise empty Todo
      // placeholder instead of silently posting the requested text as a Todo.
      composerDraft.setComposerMode(.text)
      presentComposerDraftEditor()
    case .photo:
      presentPhotoCapture()
    case .voice:
      presentVoiceRecorder()
    case .doodle:
      presentDoodleCanvas()
    case .suggestion:
      guard JournalFeatureFlags.isJournalingSuggestionsCaptureEnabled else {
        onSystemCaptureFailure(
          String(localized: "Journaling Suggestions are not available in this build of Journal.")
        )
        return
      }
      isSuggestionCapturePresented = true
    }
  }

  private func presentComposerDraftEditor() {
    composerDraftEditorPresentation = ComposerDraftEditorPresentation(
      target: composerDraft
    )
  }

  private func requestComposerDraftDiscard() {
    guard composerDraft.isEmptyComposerDraft == false else { return }
    isDiscardComposerDraftConfirmationPresented = true
  }

  private func resetComposerDraft() {
    composerState.discardActiveDraft()
    composerDraftEditorPresentation = nil
  }

  private func discardAllComposerDrafts() {
    composerState.discardAllDrafts()
    navigationPath.removeAll(keepingCapacity: false)
    savedListScrollRequest = nil
    composerDraftEditorPresentation = nil
  }

  private func presentLinkCapture() {
    composerDraft.kind = .link
    linkEditorPresentation = LinkEditorPresentation(target: composerDraft)
  }

  private func restoreEmptyLinkPlaceholderIfNeeded() {
    restoreEmptyComposerPlaceholderIfNeeded()
  }

  /// Returns a cleared non-text editor to the direct text input without
  /// discarding invalid-but-authored values such as an incomplete URL.
  private func restoreEmptyComposerPlaceholderIfNeeded() {
    guard composerDraft.kind != .text,
      composerDraft.isCurrentKindContentEmpty
    else {
      return
    }

    composerDraft.resetToEmptyTextPlaceholder()
  }

  private func presentPhotoCapture() {
    photoCapturePresentation = PhotoCapturePresentation(target: composerDraft)
  }

  private func presentLibraryMediaPicker() {
    Task { @MainActor in
      do {
        try await PhotoLibraryImport.ensurePhotoLibraryReadAccess()
        isLibraryMediaPickerPresented = true
      } catch {
        photoLibraryImportLog.error(
          "Photo library permission request failed: \(String(describing: error), privacy: .public)"
        )
        notifications.post(.mediaImportFailed)
      }
    }
  }

  private func presentDoodleCanvas() {
    quickDoodleSheetDetent = .large
    quickDoodleCanvasPresentation = DoodleCanvasPresentation(
      target: composerDraft
    )
  }

  private func presentBauhausGrid() {
    quickBauhausSheetDetent = .large
    quickBauhausGridPresentation = BauhausGridPresentation(
      target: composerDraft
    )
  }

  private func presentVoiceRecorder() {
    voiceRecorderPresentation = VoiceRecorderPresentation(target: composerDraft)
  }

  private func finishPhotoCapture(
    _ photo: CapturedPhoto,
    target: CardEditDraft
  ) {
    target.setPhoto(photo)
    attachLocationIfNeeded(to: target)
  }

  private func importMediaFromLibrary(_ item: PhotosPickerItem) {
    guard isImportingMediaFromLibrary == false else {
      return
    }

    // A picker transfer can suspend for seconds. Freeze the owning draft now
    // so selecting another Reply cannot redirect the imported payload.
    let target = composerDraft
    isImportingMediaFromLibrary = true

    Task { @MainActor in
      defer { isImportingMediaFromLibrary = false }

      do {
        let media = try await PhotoLibraryImport.importedMedia(from: item)
        finishLibraryMediaImport(media, target: target)
      } catch {
        let supportedContentTypes = item.supportedContentTypes
          .map(\.identifier)
          .joined(separator: ",")
        photoLibraryImportLog.error(
          """
          Media import failed: \(String(describing: error), privacy: .public); \
          itemIdentifier: \(item.itemIdentifier ?? "nil", privacy: .private); \
          supportedContentTypes: \(supportedContentTypes, privacy: .public)
          """
        )
        notifications.post(.mediaImportFailed)
      }
    }
  }

  private func finishLibraryMediaImport(
    _ media: PhotoLibraryImportedMedia,
    target: CardEditDraft
  ) {
    switch media {
    case .photo(let photo):
      target.setPhoto(photo)
    case .video(let video):
      target.setVideo(video)
    case .livePhoto(let livePhoto):
      target.setLivePhoto(livePhoto)
    }

    attachLocationIfNeeded(to: target)
  }

  private func updateDoodle(
    _ drawing: DoodleDrawing?,
    presentation: DoodleCanvasPresentation
  ) {
    guard let drawing else {
      clearDoodle(for: presentation)
      return
    }

    presentation.target.setDoodle(drawing)
    attachLocationIfNeeded(to: presentation.target)
  }

  private func clearDoodle(for presentation: DoodleCanvasPresentation) {
    presentation.target.resetToEmptyTextPlaceholder()
  }

  private func updateBauhaus(
    _ document: BauhausGridDocument?,
    presentation: BauhausGridPresentation
  ) {
    guard let document, document.artwork.isEmpty == false else {
      clearBauhaus(for: presentation)
      return
    }

    presentation.target.setBauhaus(document)
    attachLocationIfNeeded(to: presentation.target)
  }

  private func clearBauhaus(for presentation: BauhausGridPresentation) {
    presentation.target.resetToEmptyTextPlaceholder()
  }

  private func finishVoiceRecording(
    _ recording: AudioRecording,
    target: CardEditDraft
  ) {
    target.setAudio(recording)
    attachLocationIfNeeded(to: target)
  }

  private func finishSuggestionCapture(_ capturedSuggestion: CapturedSuggestion) {
    composerDraft.setSuggestion(
      SuggestionCardPayload(capturedSuggestion: capturedSuggestion)
    )
    attachLocationToComposerDraftIfNeeded()
  }

  private func updateComposerLocationForTextChange() {
    switch composerDraft.kind {
    case .text, .todo, .link:
      if composerDraft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        composerDraft.location = nil
      } else {
        attachLocationToComposerDraftIfNeeded()
      }
    case .file, .photo, .video, .livePhoto, .audio, .suggestion, .doodle, .bauhaus, .unknown:
      break
    @unknown default:
      break
    }
  }

  private func attachLocationToComposerDraftIfNeeded() {
    attachLocationIfNeeded(to: composerDraft)
  }

  /// Attaches one resolved coordinate to the draft that initiated the request.
  ///
  /// Reply selection can change while Core Location is suspended. Every draft
  /// that needs a coordinate subscribes by identity to the shared one-shot fix,
  /// so the result is never redirected through the currently active composer.
  private func attachLocationIfNeeded(to target: CardEditDraft) {
    guard shouldAttachLocationToNewCards,
      target.canSave,
      target.location == nil
    else {
      return
    }

    locationRequestTargets[ObjectIdentifier(target)] = target
    guard locationRequestID == nil else { return }

    let requestID = UUID()
    locationRequestID = requestID

    Task { @MainActor in
      let location = await locationManager.requestCoordinate()

      guard locationRequestID == requestID else {
        return
      }
      let targets = Array(locationRequestTargets.values)
      locationRequestTargets.removeAll(keepingCapacity: true)
      locationRequestID = nil

      guard let location, shouldAttachLocationToNewCards else { return }
      for target in targets where target.canSave && target.location == nil {
        target.location = location
      }
    }
  }

  private func clearLocationFromComposerDraft() {
    composerDraft.location = nil
  }

  private func noteCollaborationShareUpdated(_ vaultID: VaultID) async {
    await vaultRuntime.refreshCollaborationShares()
  }

  private func noteCollaborationSharingStopped(_ vaultID: VaultID) async {
    await vaultRuntime.noteSharingStopped(for: vaultID)
  }

  private func presentCollaborationError(_ error: any Error) {
    collaborationError = CollaborationErrorMessage(message: error.localizedDescription)
  }

  private func post() {
    guard composerDraft.canSave, isSaving == false else { return }
    guard let vault = activePostVault else {
      notifications.post(.cardPostFailed)
      return
    }

    // Freeze the selected vault, authored draft, and relationship before any
    // suspension point. A later vault or Reply selection cannot retarget this
    // in-flight post, and failure leaves the live draft untouched for retry.
    let targetDraft = composerDraft
    let destination = composerState.activeDestination
    let snapshot = targetDraft.savingSnapshot()
    isSaving = true

    Task { @MainActor in
      defer { isSaving = false }

      do {
        let vaultDraft = try snapshot.vaultDraft()
        let createdEdge: CardEdge
        switch destination {
        case .root:
          guard let rootEdge = try vault.createPost(cards: [vaultDraft]).first else {
            throw CreationPostError.missingCreatedEdge
          }
          createdEdge = rootEdge
          savedListScrollRequest = SavedListScrollRequest(
            ownerRootEdgeID: createdEdge.id,
            targetEdgeID: createdEdge.id
          )
        case .reply(let replyTarget):
          createdEdge = try vault.appendCard(vaultDraft, to: replyTarget.parentEdgeID)
          savedListScrollRequest = SavedListScrollRequest(
            ownerRootEdgeID: replyTarget.ownerRootEdgeID,
            targetEdgeID: createdEdge.id
          )
        }
        composerState.completePost(for: destination, ifMatching: targetDraft)
        dismissPresentations(ownedBy: targetDraft)
        notifications.post(.cardPosted)
        await vaultRuntime.refresh()
        if case .root = destination {
          WidgetCenter.shared.reloadTimelines(ofKind: JournalWidgetKind.latestNote)
        }
      } catch {
        notifications.post(.cardPostFailed)
      }
    }
  }

  /// Dismisses only editors that still belong to the draft that was posted.
  /// A user may select another Reply while persistence is running; a successful
  /// older post must not close an editor that now belongs to the newer target.
  private func dismissPresentations(ownedBy draft: CardEditDraft) {
    if composerDraftEditorPresentation?.target === draft {
      composerDraftEditorPresentation = nil
    }
    if linkEditorPresentation?.target === draft {
      linkEditorPresentation = nil
    }
    if photoCapturePresentation?.target === draft {
      photoCapturePresentation = nil
    }
    if voiceRecorderPresentation?.target === draft {
      voiceRecorderPresentation = nil
    }
    if quickDoodleCanvasPresentation?.target === draft {
      quickDoodleCanvasPresentation = nil
    }
    if quickBauhausGridPresentation?.target === draft {
      quickBauhausGridPresentation = nil
    }
  }

  /// Posts every successfully transferred item as its own Home root.
  ///
  /// The selected `VaultInstance` is captured before the asynchronous task
  /// begins, so Reply or vault selection cannot retarget an in-flight drop.
  /// No composer draft participates in this path.
  private func postDroppedHomeItems(_ items: [HomeDropItem]) {
    guard items.isEmpty == false else { return }
    guard composerState.placement.acceptsHomeDrop, isPostingHomeDrop == false else {
      for item in items {
        item.cleanUpTemporaryFiles()
      }
      return
    }
    guard let vault = vaultRuntime.selectedVault,
      vault.descriptor.permission != .readOnly
    else {
      for item in items {
        item.cleanUpTemporaryFiles()
      }
      notifications.post(.droppedContentPostFailed)
      return
    }

    HomeDropItem.cleanUpStaleTemporaryFiles()
    isPostingHomeDrop = true

    Task { @MainActor in
      defer { isPostingHomeDrop = false }

      let result = HomeDropPostingCoordinator.post(
        items: items,
        postCard: { draft in
          guard let rootEdge = try vault.createPost(cards: [draft]).first else {
            throw CreationPostError.missingCreatedEdge
          }
          return rootEdge.id
        },
        onFailure: { index, diagnostic in
          homeDropImportLog.error(
            "Dropped item \(index, privacy: .public) failed: \(diagnostic, privacy: .private)"
          )
        }
      )

      if let newestPostedEdgeID = result.postedEdgeIDs.last {
        savedListScrollRequest = SavedListScrollRequest(
          ownerRootEdgeID: newestPostedEdgeID,
          targetEdgeID: newestPostedEdgeID
        )
        await vaultRuntime.refresh()
        WidgetCenter.shared.reloadTimelines(ofKind: JournalWidgetKind.latestNote)
      }

      switch (result.postedCount, result.failedCount) {
      case (0, _):
        notifications.post(.droppedContentPostFailed)
      case (_, 0):
        notifications.post(.cardPosted)
      default:
        notifications.post(.droppedContentPartiallyPosted)
      }
    }
  }

}

/// Presentation payload for a collaboration management error.
private struct CollaborationErrorMessage: Identifiable {

  /// Stable identity for one alert presentation.
  let id = UUID()

  /// User-facing failure reason from the system sharing boundary.
  let message: String
}

/// Presentation payload for editing the card currently held by the composer.
private struct ComposerDraftEditorPresentation: Identifiable {

  /// A stable identity for one presentation. Reopening the same card rebuilds
  /// focus, capture sessions, and editor-local state cleanly.
  let id = UUID()

  /// The one unpublished card owned by the input bar.
  let target: CardEditDraft
}

/// Presentation payload for one link editor session.
private struct LinkEditorPresentation: Identifiable {

  /// A stable identity for one editor presentation. Reopening the same card gets
  /// a fresh value so SwiftUI rebuilds focus and keyboard state cleanly.
  let id = UUID()

  /// Draft being edited by the link sheet.
  let target: CardEditDraft
}

/// Presentation payload for one photo capture session.
private struct PhotoCapturePresentation: Identifiable {

  /// A stable identity for one camera presentation. Reopening the same card gets
  /// a fresh value so SwiftUI rebuilds the camera session cleanly.
  let id = UUID()

  /// The composer card that receives a successful capture.
  let target: CardEditDraft
}

/// Presentation payload for drawing into the current composer card.
private struct DoodleCanvasPresentation: Identifiable {

  /// A stable identity for one canvas presentation.
  let id = UUID()

  /// The composer card receiving streamed drawing changes.
  let target: CardEditDraft
}

/// Presentation payload for composing Bauhaus art in the current card.
private struct BauhausGridPresentation: Identifiable {

  /// A stable identity for one grid presentation.
  let id = UUID()

  /// The composer card receiving streamed grid changes.
  let target: CardEditDraft
}

/// Presentation payload for one voice recorder session.
private struct VoiceRecorderPresentation: Identifiable {

  /// A stable identity for one recorder presentation. Reopening the same card gets
  /// a fresh value so SwiftUI rebuilds the recorder session cleanly.
  let id = UUID()

  /// The composer card that receives a completed recording.
  let target: CardEditDraft
}

/// Media value produced by one Photos library picker selection.
private enum PhotoLibraryImportedMedia {
  case photo(CapturedPhoto)
  case video(CapturedVideo)
  case livePhoto(CapturedLivePhoto)
}

/// Converts a user-selected Photos item into a draft payload while preserving
/// compound resources such as Live Photo paired movies.
private enum PhotoLibraryImport {

  @MainActor
  static func importedMedia(from item: PhotosPickerItem) async throws -> PhotoLibraryImportedMedia {
    let isLivePhoto = isLivePhotoItem(item)
    if isLivePhoto {
      try await ensurePhotoLibraryReadAccess()
    }

    guard let itemIdentifier = item.itemIdentifier else {
      if isLivePhoto {
        throw PhotoLibraryImportError.livePhotoAssetUnavailable
      }
      if isVideoOnlyItem(item) {
        return .video(try await capturedVideo(from: item))
      }
      return .photo(try await capturedPhoto(from: item))
    }

    let result = PHAsset.fetchAssets(withLocalIdentifiers: [itemIdentifier], options: nil)
    guard let asset = result.firstObject else {
      if isLivePhoto {
        throw PhotoLibraryImportError.livePhotoAssetUnavailable
      }
      if isVideoOnlyItem(item) {
        return .video(try await capturedVideo(from: item))
      }
      return .photo(try await capturedPhoto(from: item))
    }

    switch asset.mediaType {
    case .image where asset.mediaSubtypes.contains(.photoLive):
      return .livePhoto(try await capturedLivePhoto(from: asset))
    case .image:
      return .photo(try await capturedPhoto(from: item))
    case .video:
      do {
        return .video(try await capturedVideo(from: asset))
      } catch {
        return .video(try await capturedVideo(from: item))
      }
    default:
      throw PhotoLibraryImportError.unsupportedAsset
    }
  }

  static func capturedPhoto(from item: PhotosPickerItem) async throws -> CapturedPhoto {
    guard let data = try await item.loadTransferable(type: Data.self) else {
      throw PhotoLibraryImportError.missingImageData
    }

    guard let image = UIImage(data: data) else {
      throw PhotoLibraryImportError.undecodableImage
    }

    guard let jpegData = image.jpegData(compressionQuality: 0.9) else {
      throw PhotoLibraryImportError.missingJPEGData
    }

    return CapturedPhoto(imageData: jpegData, pixelSize: image.size)
  }

  private static func capturedVideo(from asset: PHAsset) async throws -> CapturedVideo {
    let resource = try resource(
      in: PHAssetResource.assetResources(for: asset),
      preferredTypes: [.video, .fullSizeVideo]
    )
    let fileURL = try await export(resource)
    let thumbnail = try? MediaThumbnailGenerator.videoThumbnail(from: fileURL).data

    return CapturedVideo(
      fileURL: fileURL,
      thumbnailData: thumbnail,
      pixelSize: asset.pixelSize,
      duration: asset.duration,
      contentTypeIdentifier: resource.contentType.identifier,
      byteSize: byteSize(for: resource)
    )
  }

  private static func capturedVideo(from item: PhotosPickerItem) async throws -> CapturedVideo {
    guard let movie = try await item.loadTransferable(type: TransferredMovie.self) else {
      throw PhotoLibraryImportError.missingVideoFile
    }

    let metadata = try? await videoMetadata(from: movie.fileURL)
    let thumbnail = try? MediaThumbnailGenerator.videoThumbnail(from: movie.fileURL).data

    return CapturedVideo(
      fileURL: movie.fileURL,
      thumbnailData: thumbnail,
      pixelSize: metadata?.pixelSize ?? .zero,
      duration: metadata?.duration ?? 0,
      contentTypeIdentifier: videoContentTypeIdentifier(for: item, fileURL: movie.fileURL),
      byteSize: fileByteSize(movie.fileURL)
    )
  }

  private static func capturedLivePhoto(from asset: PHAsset) async throws -> CapturedLivePhoto {
    let resources = PHAssetResource.assetResources(for: asset)
    let stillResource = try resource(
      in: resources,
      preferredTypes: [.photo, .fullSizePhoto]
    )
    let pairedVideoResource = try resource(
      in: resources,
      preferredTypes: [.pairedVideo, .fullSizePairedVideo]
    )

    let stillFileURL = try await export(stillResource)
    let stillData = try Data(contentsOf: stillFileURL)
    try? FileManager.default.removeItem(at: stillFileURL)

    let pairedVideoFileURL = try await export(pairedVideoResource)
    let thumbnail = try? MediaThumbnailGenerator.imageThumbnail(from: stillData).data

    return CapturedLivePhoto(
      stillImageData: stillData,
      pairedVideoFileURL: pairedVideoFileURL,
      thumbnailData: thumbnail,
      pixelSize: asset.pixelSize,
      duration: asset.duration,
      stillImageContentTypeIdentifier: stillResource.contentType.identifier,
      pairedVideoContentTypeIdentifier: pairedVideoResource.contentType.identifier,
      stillImageByteSize: byteSize(for: stillResource) ?? stillData.count,
      pairedVideoByteSize: byteSize(for: pairedVideoResource)
    )
  }

  private static func resource(
    in resources: [PHAssetResource],
    preferredTypes: [PHAssetResourceType]
  ) throws -> PHAssetResource {
    for type in preferredTypes {
      if let resource = resources.first(where: { $0.type == type }) {
        return resource
      }
    }

    throw PhotoLibraryImportError.missingResource
  }

  private static func export(_ resource: PHAssetResource) async throws -> URL {
    let fileURL = temporaryFileURL(for: resource)
    let options = PHAssetResourceRequestOptions()
    options.isNetworkAccessAllowed = true

    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, any Error>) in
      PHAssetResourceManager.default().writeData(
        for: resource,
        toFile: fileURL,
        options: options
      ) { error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume()
        }
      }
    }

    return fileURL
  }

  private static func temporaryFileURL(for resource: PHAssetResource) -> URL {
    let originalExtension = URL(fileURLWithPath: resource.originalFilename).pathExtension
    let fallbackExtension = resource.contentType.preferredFilenameExtension ?? "dat"
    let pathExtension = originalExtension.isEmpty ? fallbackExtension : originalExtension
    return FileManager.default.temporaryDirectory
      .appendingPathComponent("journal-library-\(UUID().uuidString)")
      .appendingPathExtension(pathExtension)
  }

  private static func byteSize(for _: PHAssetResource) -> Int? {
    nil
  }

  fileprivate static func ensurePhotoLibraryReadAccess() async throws {
    switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
    case .authorized, .limited:
      return
    case .notDetermined:
      let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
      guard status == .authorized || status == .limited else {
        throw PhotoLibraryImportError.photoLibraryReadAccessDenied
      }
    case .denied, .restricted:
      throw PhotoLibraryImportError.photoLibraryReadAccessDenied
    @unknown default:
      throw PhotoLibraryImportError.photoLibraryReadAccessDenied
    }
  }

  private static func isVideoOnlyItem(_ item: PhotosPickerItem) -> Bool {
    item.supportedContentTypes.contains(where: isVideoContentType)
      && item.supportedContentTypes.contains(where: { $0.conforms(to: .image) }) == false
  }

  private static func isLivePhotoItem(_ item: PhotosPickerItem) -> Bool {
    item.supportedContentTypes.contains(where: isLivePhotoContentType)
  }

  private static func isLivePhotoContentType(_ contentType: UTType) -> Bool {
    guard let livePhotoContentType = UTType("com.apple.live-photo") else {
      return false
    }

    return contentType == livePhotoContentType
      || contentType.conforms(to: livePhotoContentType)
  }

  private static func isVideoContentType(_ contentType: UTType) -> Bool {
    contentType.conforms(to: .movie)
      || contentType.conforms(to: .video)
      || contentType.conforms(to: .audiovisualContent)
  }

  private static func videoContentTypeIdentifier(
    for item: PhotosPickerItem,
    fileURL: URL
  ) -> String {
    item.supportedContentTypes.first(where: isVideoContentType)?.identifier
      ?? UTType(filenameExtension: fileURL.pathExtension)?.identifier
      ?? UTType.movie.identifier
  }

  private static func videoMetadata(from fileURL: URL) async throws -> VideoFileMetadata {
    let asset = AVURLAsset(url: fileURL)
    let duration = try await asset.load(.duration)
    let tracks = try await asset.loadTracks(withMediaType: .video)

    guard let track = tracks.first else {
      return VideoFileMetadata(pixelSize: .zero, duration: duration.safeSeconds)
    }

    let naturalSize = try await track.load(.naturalSize)
    let preferredTransform = try await track.load(.preferredTransform)
    let transformedSize = naturalSize.applying(preferredTransform)
    return VideoFileMetadata(
      pixelSize: CGSize(
        width: abs(transformedSize.width),
        height: abs(transformedSize.height)
      ),
      duration: duration.safeSeconds
    )
  }

  private static func fileByteSize(_ fileURL: URL) -> Int {
    (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
  }
}

/// Movie file copied out of a PhotosPicker transfer.
///
/// `PHPicker` can vend media without exposing a `PHAsset` identifier. In that
/// case, videos still need to enter Journal as files instead of going through
/// the still-image `Data` fallback.
private struct TransferredMovie: Transferable {
  var fileURL: URL

  static var transferRepresentation: some TransferRepresentation {
    FileRepresentation(contentType: .movie) { movie in
      SentTransferredFile(movie.fileURL)
    } importing: { received in
      let pathExtension = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
      let copyURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("journal-picker-video-\(UUID().uuidString)")
        .appendingPathExtension(pathExtension)
      try FileManager.default.copyItem(at: received.file, to: copyURL)
      return TransferredMovie(fileURL: copyURL)
    }
  }
}

/// Lightweight metadata needed to render and persist a transferred video.
private struct VideoFileMetadata {
  var pixelSize: CGSize
  var duration: TimeInterval
}

/// Failure cases from importing one selected Photos media item.
private enum PhotoLibraryImportError: Error {
  case missingImageData
  case undecodableImage
  case missingJPEGData
  case missingResource
  case missingVideoFile
  /// PhotoKit read access is required when Journal needs to export the paired
  /// movie resource for a Live Photo.
  case photoLibraryReadAccessDenied
  /// The picker identified a Live Photo, but Journal could not resolve the
  /// backing `PHAsset` required to export its still image and paired movie.
  case livePhotoAssetUnavailable
  case unsupportedAsset
}

extension PHAsset {
  fileprivate var pixelSize: CGSize {
    CGSize(width: pixelWidth, height: pixelHeight)
  }
}

extension CMTime {
  fileprivate var safeSeconds: TimeInterval {
    seconds.isFinite ? seconds : 0
  }
}

/// Concrete Journal actions shown inside the standard SwiftUI add menu.
private struct CreationAddMenuContent: View {

  let isSuggestionCaptureEnabled: Bool
  let onComposeLink: @MainActor @Sendable () -> Void
  let onCapturePhoto: @MainActor @Sendable () -> Void
  let onChooseMediaFromLibrary: @MainActor @Sendable () -> Void
  let onDrawDoodle: @MainActor @Sendable () -> Void
  let onComposeBauhaus: @MainActor @Sendable () -> Void
  let onRecordVoice: @MainActor @Sendable () -> Void
  let onChooseSuggestion: @MainActor @Sendable (CapturedSuggestion) -> Void

  var body: some View {
    Button(action: onComposeLink) {
      Label("Link", systemImage: "link")
    }

    Button(action: onCapturePhoto) {
      Label("Camera", systemImage: "camera")
    }

    Button(action: onChooseMediaFromLibrary) {
      Label("Photos", systemImage: "photo.on.rectangle.angled")
    }

    Button(action: onComposeBauhaus) {
      Label("Bauhaus", systemImage: "square.grid.3x3.square")
    }

    Button(action: onDrawDoodle) {
      Label("Doodle", systemImage: "scribble.variable")
    }

    Button(action: onRecordVoice) {
      Label("Voice", systemImage: "waveform")
    }

    if isSuggestionCaptureEnabled {
      SuggestionCaptureButton {
        Label("Suggestion", systemImage: "sparkles")
      } onCommit: { suggestion in
        onChooseSuggestion(suggestion)
      }
      .accessibilityLabel(Text("Suggestion"))
    }
  }
}

private struct CreationVaultToolbarLabel: View {

  let title: String
  let icon: VaultIcon

  var body: some View {
    HStack(spacing: 6) {
      switch icon.kind {
      case .systemImage:
        Image(systemName: icon.value)
      case .emoji:
        Text(icon.value)
      }

      Text(title)
    }
    .padding(.horizontal, 4)
  }
}

extension Card.Kind {

  /// User-facing name for the editor modality.
  var displayTitle: LocalizedStringResource {
    switch self {
    case .text:
      return "Text"
    case .todo:
      return "Todo"
    case .link:
      return "Link"
    case .file:
      return "File"
    case .photo:
      return "Photo"
    case .video:
      return "Video"
    case .livePhoto:
      return "Live Photo"
    case .audio:
      return "Audio"
    case .suggestion:
      return "Suggestion"
    case .doodle:
      return "Doodle"
    case .bauhaus:
      return "Bauhaus"
    case .unknown:
      return "Unknown"
    @unknown default:
      return "Unknown"
    }
  }

}
