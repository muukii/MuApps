import AppUIComponents
import AVFoundation
import CaptureAudio
import CaptureBauhaus
import CaptureDoodle
import CapturePhoto
import CoreTransferable
import CoreLocation
import JournalVault
import MediaProcessing
import MuColor
import OSLog
import Photos
import PhotosUI
import ScrollEdgeEffect
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import WidgetKit

private let photoLibraryImportLog = Logger(subsystem: "app.muukii.journal", category: "PhotoLibraryImport")

struct CreationView: View {

  private let onChangeVault: (@MainActor @Sendable () -> Void)?

  @Environment(JournalNotificationCenter.self) private var notifications
  @Environment(JournalVaultRuntime.self) private var vaultRuntime

  init(onChangeVault: (@MainActor @Sendable () -> Void)? = nil) {
    self.onChangeVault = onChangeVault
  }

  @AppStorage(JournalDefaults.shouldAttachLocationToNewCards)
  private var shouldAttachLocationToNewCards: Bool = true

  @State private var draftCards: [ThreadDraftCard] = []
  @State private var textEditorPresentation: TextEditorPresentation?
  @State private var linkEditorPresentation: LinkEditorPresentation?
  @State private var photoCapturePresentation: PhotoCapturePresentation?
  @State private var doodleCanvasPresentation: DoodleCanvasPresentation?
  @State private var bauhausGridPresentation: BauhausGridPresentation?
  @State private var voiceRecorderPresentation: VoiceRecorderPresentation?
  @State private var quickDoodleCanvasPresentation: DoodleCanvasPresentation?
  @State private var quickBauhausGridPresentation: BauhausGridPresentation?
  @State private var quickDoodleSheetDetent: PresentationDetent = .large
  @State private var quickBauhausSheetDetent: PresentationDetent = .large
  @State private var scrollTargetID: ThreadDraftCard?
  @State private var isSettingsPresented: Bool = false
  @State private var isChangeVaultConfirmationPresented = false
  @State private var isImportingMediaFromLibrary: Bool = false
  @State private var collaborationError: CollaborationErrorMessage?
  @Namespace private var namespace

  /// Shared one-shot location bridge. Each draft card stores the resolved
  /// coordinate it wants to persist; this object only handles permission and
  /// the current coordinate lookup.
  @State private var locationManager = LocationManager()

  /// Guards the compose surface while a save is in flight, so a card can't be
  /// created twice by a fast double-tap.
  @State private var isSaving: Bool = false

  var body: some View {

    NavigationStack {
      ZStack {
        Rectangle()
          .fill(.background)
          .ignoresSafeArea(edges: .all)

        ScrollView {

          VStack(spacing: 20) {
            ForEach(draftCards, id: \.self) { draft in
              ThreadDraftCardEditor(
                card: draft,
                isSaving: isSaving,
                onOpen: {
                  openDraft(draft)
                }
              )
              .matchedTransitionSource(id: draft, in: namespace)
              .containerRelativeFrame(.horizontal) { length, _ in
                length * 0.5
              }
            }

          }
          .frame(maxWidth: .infinity)
          .scrollTargetLayout()
          .padding(.horizontal, 16)
          .padding(.top, 16)
        }
        .scrollPosition(id: $scrollTargetID, anchor: .center)
        .scrollTargetBehavior(.viewAligned)

      }
      .toolbarTitleDisplayMode(.inlineLarge)
      .toolbar(content: {
        if onChangeVault != nil {
          ToolbarItem(placement: .navigationBarLeading) {
            Button {
              requestVaultChange()
            } label: {
              Label(vaultRuntime.selectedVault?.title ?? String(localized: "Vault"), systemImage: "shippingbox")
            }
            .accessibilityLabel("Change Vault")
          }
        }

        if let collaborationVault = selectedCollaborationVault {
          ToolbarItem(placement: .navigationBarTrailing) {
            VaultCollaborationControl(
              vaultID: collaborationVault.vaultID,
              title: collaborationVault.title,
              prepareShare: prepareCollaborationShare,
              onSharingStopped: noteCollaborationSharingStopped,
              onError: presentCollaborationError
            )
            .id(collaborationVault.vaultID)
            .frame(width: 36, height: 36)
          }
        }

        ToolbarItem(placement: .navigationBarTrailing) {
          NavigationLink.init {
            SavedListView()
              .navigationTransition(.zoom(sourceID: "list", in: namespace))
          } label: {
            Image(systemName: "calendar")
          }
          .matchedTransitionSource(id: "list", in: namespace)
        }

        ToolbarItem(placement: .navigationBarTrailing) {
          Button(action: {
            isSettingsPresented.toggle()
          }) {
            Image(systemName: "gearshape")
          }
          .matchedTransitionSource(id: "settings", in: namespace)
        }
      })
      .safeAreaInset(edge: .top, content: {
        DateView()
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal)
      })
      .safeAreaInset(edge: .bottom) {
        ThreadDraftActionRow(
          draftCards: draftCards,
          isSaving: isSaving || isImportingMediaFromLibrary,
          onComposeText: {
            presentTextCapture()
          },
          onComposeLink: {
            presentLinkCapture()
          },
          onCapturePhoto: {
            presentPhotoCapture()
          },
          onChooseMediaFromLibrary: { item in
            importMediaFromLibrary(item)
          },
          onMediaPickerUnavailable: {
            notifications.post(.mediaImportFailed)
          },
          onDrawDoodle: {
            presentDoodleCanvas()
          },
          onComposeBauhaus: {
            presentBauhausGrid()
          },
          onRecordVoice: {
            presentVoiceRecorder()
          },
          onSave: save
        )
        .padding(.horizontal)
      }
    }
    .sheet(item: $textEditorPresentation) { presentation in
      ThreadDraftTextEditorSheet(
        card: presentation.target
      )
      .presentationDetents([.medium, .large])
      .presentationDragIndicator(.visible)
      .presentationBackground(.background)
    }
    .sheet(item: $linkEditorPresentation) { presentation in
      ThreadDraftLinkEditorSheet(
        card: presentation.target
      )
      .presentationDetents([.medium, .large])
      .presentationDragIndicator(.visible)
      .presentationBackground(.background)
    }
    .fullScreenCover(item: $doodleCanvasPresentation) { presentation in
      ThreadDraftDoodleCanvasCover(
        card: presentation.target,
        onChange: { drawing in
          updateDoodle(drawing, presentation: presentation)
        }
      )
    }
    .sheet(item: $quickDoodleCanvasPresentation) { presentation in
      ThreadDraftDoodleCanvasSheet(
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
    .sheet(item: $bauhausGridPresentation) { presentation in
      ThreadDraftBauhausGridSheet(
        card: presentation.target,
        onChange: { document in
          updateBauhaus(document, presentation: presentation)
        }
      )
      .presentationDetents([.medium, .large])
      .presentationDragIndicator(.visible)
      .presentationBackground(.background)
    }
    .sheet(item: $quickBauhausGridPresentation) { presentation in
      ThreadDraftBauhausGridSheet(
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
      ThreadDraftPhotoCaptureSheet(
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
      ThreadDraftVoiceRecorderSheet(
        card: presentation.target,
        onFinish: { recording in
          finishVoiceRecording(recording, target: presentation.target)
        }
      )
      .presentationDetents([.medium, .large])
      .presentationDragIndicator(.visible)
      .presentationBackground(.background)
    }
    .sheet(isPresented: $isSettingsPresented) {
      SettingsScreen()
        .navigationTransition(.zoom(sourceID: "settings", in: namespace))
        .presentationBackground(.background)
    }
    .confirmationDialog(
      "Discard Drafts?",
      isPresented: $isChangeVaultConfirmationPresented,
      titleVisibility: .visible
    ) {
      Button("Discard and Change Vault", role: .destructive) {
        onChangeVault?()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Drafts are kept only in the current composer.")
    }
    .alert(item: $collaborationError) { error in
      Alert(
        title: Text("Could Not Manage Collaboration"),
        message: Text(error.message),
        dismissButton: .default(Text("OK"))
      )
    }
    .appNavigationBarStyle()
    .onAppear {
      attachLocationToCurrentDraftsIfNeeded()
    }
    .onChange(of: shouldAttachLocationToNewCards) { _, isEnabled in
      if isEnabled {
        attachLocationToCurrentDraftsIfNeeded()
      } else {
        clearLocationFromCurrentDrafts()
      }
    }
    .onChange(of: locationManager.authorizationStatus) { _, status in
      // System access can be revoked after a coordinate was attached. Clear
      // draft coordinates so the UI never claims location metadata it can no
      // longer justify.
      switch status {
      case .denied, .restricted:
        clearLocationFromCurrentDrafts()
      case .authorizedWhenInUse, .authorizedAlways:
        attachLocationToCurrentDraftsIfNeeded()
      case .notDetermined:
        break
      @unknown default:
        break
      }
    }

  }

  private var selectedVaultDescriptor: VaultDescriptor? {
    guard let selectedVault = vaultRuntime.selectedVault else {
      return nil
    }

    return vaultRuntime.vaults.first { $0.vaultID == selectedVault.vaultID } ?? selectedVault.descriptor
  }

  private var selectedCollaborationVault: VaultDescriptor? {
    guard let descriptor = selectedVaultDescriptor,
          descriptor.ownership == .owned,
          descriptor.isShared else {
      return nil
    }

    return descriptor
  }

  private func requestVaultChange() {
    guard let onChangeVault else { return }

    if draftCards.isEmpty {
      onChangeVault()
    } else {
      isChangeVaultConfirmationPresented = true
    }
  }

  private func presentTextCapture() {
    if let draft = draftCards.last, draft.isEmptyTextDraft {
      scrollTargetID = draft
      attachLocationToCurrentDraftsIfNeeded()
      presentTextEditor(for: draft)
      return
    }

    let draft = ThreadDraftCard()
    draftCards.append(draft)
    scrollTargetID = draft
    attachLocationToCurrentDraftsIfNeeded()
    presentTextEditor(for: draft)
  }

  private func openDraft(_ draft: ThreadDraftCard) {
    switch draft.kind {
    case .photo:
      photoCapturePresentation = PhotoCapturePresentation(target: draft)
    case .video, .livePhoto:
      break
    case .audio:
      voiceRecorderPresentation = VoiceRecorderPresentation(target: draft)
    case .doodle:
      doodleCanvasPresentation = DoodleCanvasPresentation(
        target: draft,
        isQuickCapture: false
      )
    case .bauhaus:
      bauhausGridPresentation = BauhausGridPresentation(
        target: draft,
        isQuickCapture: false
      )
    case .text:
      presentTextEditor(for: draft)
    case .link:
      presentLinkEditor(for: draft)
    case .unknown:
      presentTextEditor(for: draft)
    }
  }

  private func presentTextEditor(for draft: ThreadDraftCard) {
    textEditorPresentation = TextEditorPresentation(target: draft)
  }

  private func presentLinkCapture() {
    let draft: ThreadDraftCard

    if let lastDraft = draftCards.last, lastDraft.isEmptyTextDraft {
      draft = lastDraft
      draft.kind = .link
    } else {
      draft = ThreadDraftCard(kind: .link)
      draftCards.append(draft)
    }

    scrollTargetID = draft
    attachLocationToCurrentDraftsIfNeeded()
    presentLinkEditor(for: draft)
  }

  private func presentLinkEditor(for draft: ThreadDraftCard) {
    linkEditorPresentation = LinkEditorPresentation(target: draft)
  }

  private func presentPhotoCapture() {
    photoCapturePresentation = PhotoCapturePresentation(target: nil)
  }

  private func presentDoodleCanvas() {
    quickDoodleSheetDetent = .large
    quickDoodleCanvasPresentation = DoodleCanvasPresentation(
      target: nil,
      isQuickCapture: true
    )
  }

  private func presentBauhausGrid() {
    quickBauhausSheetDetent = .large
    quickBauhausGridPresentation = BauhausGridPresentation(
      target: nil,
      isQuickCapture: true
    )
  }

  private func presentVoiceRecorder() {
    voiceRecorderPresentation = VoiceRecorderPresentation(target: nil)
  }

  private func finishPhotoCapture(
    _ photo: CapturedPhoto,
    target: ThreadDraftCard?
  ) {
    let draft = target ?? draftForNewQuickCapture()
    draft.setPhoto(photo)
    scrollTargetID = draft
    attachLocationToCurrentDraftsIfNeeded()
  }

  private func importMediaFromLibrary(_ item: PhotosPickerItem) {
    guard isImportingMediaFromLibrary == false else {
      return
    }

    isImportingMediaFromLibrary = true

    Task { @MainActor in
      defer { isImportingMediaFromLibrary = false }

      do {
        let media = try await PhotoLibraryImport.importedMedia(from: item)
        finishLibraryMediaImport(media)
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

  private func finishLibraryMediaImport(_ media: PhotoLibraryImportedMedia) {
    let draft = draftForNewQuickCapture()
    switch media {
    case .photo(let photo):
      draft.setPhoto(photo)
    case .video(let video):
      draft.setVideo(video)
    case .livePhoto(let livePhoto):
      draft.setLivePhoto(livePhoto)
    }

    scrollTargetID = draft
    attachLocationToCurrentDraftsIfNeeded()
  }

  private func updateDoodle(
    _ drawing: DoodleDrawing?,
    presentation: DoodleCanvasPresentation
  ) {
    guard let drawing else {
      clearDoodle(for: presentation)
      return
    }

    let draft = presentation.target ?? draftForNewDoodleCapture(presentation)
    draft.setDoodle(drawing)
    scrollTargetID = draft
    attachLocationToCurrentDraftsIfNeeded()
  }

  private func draftForNewDoodleCapture(
    _ presentation: DoodleCanvasPresentation
  ) -> ThreadDraftCard {
    if let draft = presentation.target {
      return draft
    }

    if let draft = draftCards.last, draft.isEmptyTextDraft {
      presentation.target = draft
      presentation.reusesPlaceholder = true
      return draft
    }

    let draft = ThreadDraftCard()
    draftCards.append(draft)
    presentation.target = draft
    presentation.ownsInsertedDraft = true
    return draft
  }

  private func clearDoodle(for presentation: DoodleCanvasPresentation) {
    guard let draft = presentation.target else {
      return
    }

    guard presentation.isQuickCapture else {
      draft.clearDoodle()
      return
    }

    if presentation.ownsInsertedDraft {
      draftCards.removeAll { $0 == draft }
      presentation.target = nil
      presentation.ownsInsertedDraft = false
    } else if presentation.reusesPlaceholder {
      draft.resetToEmptyTextPlaceholder()
      presentation.target = nil
      presentation.reusesPlaceholder = false
    } else {
      draft.clearDoodle()
    }
  }

  private func updateBauhaus(
    _ document: BauhausGridDocument?,
    presentation: BauhausGridPresentation
  ) {
    guard let document, document.artwork.isEmpty == false else {
      clearBauhaus(for: presentation)
      return
    }

    let draft = presentation.target ?? draftForNewBauhausCapture(presentation)
    draft.setBauhaus(document)
    scrollTargetID = draft
    attachLocationToCurrentDraftsIfNeeded()
  }

  private func draftForNewBauhausCapture(
    _ presentation: BauhausGridPresentation
  ) -> ThreadDraftCard {
    if let draft = presentation.target {
      return draft
    }

    if let draft = draftCards.last, draft.isEmptyTextDraft {
      presentation.target = draft
      presentation.reusesPlaceholder = true
      return draft
    }

    let draft = ThreadDraftCard()
    draftCards.append(draft)
    presentation.target = draft
    presentation.ownsInsertedDraft = true
    return draft
  }

  private func clearBauhaus(for presentation: BauhausGridPresentation) {
    guard let draft = presentation.target else {
      return
    }

    guard presentation.isQuickCapture else {
      draft.clearBauhaus()
      return
    }

    if presentation.ownsInsertedDraft {
      draftCards.removeAll { $0 == draft }
      presentation.target = nil
      presentation.ownsInsertedDraft = false
    } else if presentation.reusesPlaceholder {
      draft.resetToEmptyTextPlaceholder()
      presentation.target = nil
      presentation.reusesPlaceholder = false
    } else {
      draft.clearBauhaus()
    }
  }

  private func finishVoiceRecording(
    _ recording: AudioRecording,
    target: ThreadDraftCard?
  ) {
    let draft = target ?? draftForNewQuickCapture()
    draft.setAudio(recording)
    scrollTargetID = draft
    attachLocationToCurrentDraftsIfNeeded()
  }

  private func draftForNewQuickCapture() -> ThreadDraftCard {
    if let draft = draftCards.last, draft.isEmptyTextDraft {
      return draft
    }

    let draft = ThreadDraftCard()
    draftCards.append(draft)
    return draft
  }

  private func attachLocationToCurrentDraftsIfNeeded() {
    guard shouldAttachLocationToNewCards else {
      return
    }

    let targets = draftCards.filter { $0.location == nil }
    guard targets.isEmpty == false else {
      return
    }

    Task { @MainActor in
      guard let location = await locationManager.requestCoordinate() else {
        return
      }

      guard shouldAttachLocationToNewCards else {
        return
      }

      for target in targets where target.location == nil {
        target.location = location
      }
    }
  }

  private func clearLocationFromCurrentDrafts() {
    for card in draftCards {
      card.location = nil
    }
  }

  private func prepareCollaborationShare(_ vaultID: VaultID) async throws -> VaultSharePreparation {
    try await vaultRuntime.prepareShare(for: vaultID)
  }

  private func noteCollaborationSharingStopped(_ vaultID: VaultID) async {
    await vaultRuntime.noteSharingStopped(for: vaultID)
  }

  private func presentCollaborationError(_ error: any Error) {
    collaborationError = CollaborationErrorMessage(message: error.localizedDescription)
  }

  private func save() {

    let drafts = draftCards.map { $0.savingSnapshot() }

    guard drafts.isEmpty == false, isSaving == false else { return }

    // Read the thread snapshot now so persistence works from the card payloads
    // the user had authored at the moment they tapped save.
    isSaving = true

    Task { @MainActor in
      defer { isSaving = false }

      do {
        guard let vault = vaultRuntime.selectedVault else {
          notifications.post(.threadSaveFailed)
          return
        }

        let vaultDrafts = try drafts.map { try $0.vaultDraft() }
        try vault.createThread(cards: vaultDrafts)
        await vaultRuntime.refresh()
        WidgetCenter.shared.reloadTimelines(ofKind: JournalWidgetKind.latestNote)
        draftCards.removeAll()
        scrollTargetID = nil
        textEditorPresentation = nil
        linkEditorPresentation = nil
        photoCapturePresentation = nil
        doodleCanvasPresentation = nil
        bauhausGridPresentation = nil
        voiceRecorderPresentation = nil
        quickDoodleCanvasPresentation = nil
        quickBauhausGridPresentation = nil
        notifications.post(.threadSaved)
      } catch {
        // The draft is left on screen so nothing the user typed is lost.
        notifications.post(.threadSaveFailed)
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

/// Presentation payload for one text editor session.
private struct TextEditorPresentation: Identifiable {

  /// A stable identity for one editor presentation. Reopening the same card gets
  /// a fresh value so SwiftUI rebuilds focus and keyboard state cleanly.
  let id = UUID()

  /// Draft being edited by the text sheet.
  let target: ThreadDraftCard
}

/// Presentation payload for one link editor session.
private struct LinkEditorPresentation: Identifiable {

  /// A stable identity for one editor presentation. Reopening the same card gets
  /// a fresh value so SwiftUI rebuilds focus and keyboard state cleanly.
  let id = UUID()

  /// Draft being edited by the link sheet.
  let target: ThreadDraftCard
}

/// Presentation payload for one photo capture session.
private struct PhotoCapturePresentation: Identifiable {

  /// A stable identity for one camera presentation. Reopening the same card gets
  /// a fresh value so SwiftUI rebuilds the camera session cleanly.
  let id = UUID()

  /// Draft to overwrite, or `nil` when the captured photo should create/reuse a
  /// draft only after the user actually takes a photo.
  let target: ThreadDraftCard?
}

/// Presentation state for the doodle canvas.
///
/// Doodle capture streams changes while the user draws, so quick creation needs
/// a mutable presentation object that can remember which draft was resolved after
/// the first stroke.
@MainActor
private final class DoodleCanvasPresentation: Identifiable {

  /// A stable identity for one canvas presentation.
  let id = UUID()

  /// Draft currently receiving canvas changes. `nil` until the first non-empty
  /// drawing when the user starts from the quick Doodle action.
  var target: ThreadDraftCard?

  /// Whether this presentation came from the composer quick action rather than
  /// from an existing doodle card.
  let isQuickCapture: Bool

  /// Whether the quick action appended a new draft that should disappear if the
  /// canvas is cleared before dismissal.
  var ownsInsertedDraft: Bool = false

  /// Whether the quick action reused the untouched text placeholder. Clearing
  /// the canvas should restore that placeholder instead of leaving a blank doodle
  /// draft.
  var reusesPlaceholder: Bool = false

  init(target: ThreadDraftCard?, isQuickCapture: Bool) {
    self.target = target
    self.isQuickCapture = isQuickCapture
  }
}

/// Presentation state for the Bauhaus grid editor.
///
/// Bauhaus capture streams changes as cells are filled, so quick creation needs
/// a mutable presentation object that can remember which draft was resolved
/// after the first non-empty artwork arrives.
@MainActor
private final class BauhausGridPresentation: Identifiable {

  /// A stable identity for one grid presentation.
  let id = UUID()

  /// Draft currently receiving grid changes. `nil` until the first non-empty
  /// artwork when the user starts from the quick Bauhaus action.
  var target: ThreadDraftCard?

  /// Whether this presentation came from the composer quick action rather than
  /// from an existing Bauhaus card.
  let isQuickCapture: Bool

  /// Whether the quick action appended a new draft that should disappear if the
  /// grid is cleared before dismissal.
  var ownsInsertedDraft: Bool = false

  /// Whether the quick action reused the untouched text placeholder. Clearing
  /// the grid should restore that placeholder instead of leaving a blank Bauhaus
  /// draft.
  var reusesPlaceholder: Bool = false

  init(target: ThreadDraftCard?, isQuickCapture: Bool) {
    self.target = target
    self.isQuickCapture = isQuickCapture
  }
}

/// Presentation payload for one voice recorder session.
private struct VoiceRecorderPresentation: Identifiable {

  /// A stable identity for one recorder presentation. Reopening the same card gets
  /// a fresh value so SwiftUI rebuilds the recorder session cleanly.
  let id = UUID()

  /// Draft to overwrite, or `nil` when the recording should create/reuse a draft
  /// only after the user actually finishes recording.
  let target: ThreadDraftCard?
}

/// Card-shaped entry point for one draft in the creation thread.
private struct ThreadDraftCardEditor: View {

  @Bindable var card: ThreadDraftCard
  let isSaving: Bool
  let onOpen: @MainActor @Sendable () -> Void

  var body: some View {
    Button(action: onOpen) {
      DraftEntrySummaryCard(draft: card)
    }
    .buttonStyle(.plain)
    .disabled(isSaving)
    .accessibilityLabel("Edit Card")
  }
}

/// Card-shaped summary for an unsaved draft.
///
/// This view intentionally knows only about `CardEditDraft` and capture payloads.
/// It does not bridge to legacy saved-entry rendering or any persistence model.
private struct DraftEntrySummaryCard: View {

  let draft: CardEditDraft

  var body: some View {
    CardSurface {
      VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 8) {
          Image(systemName: draft.kind.creationSymbolName)
          Text(draft.kind.displayTitle)
          Spacer(minLength: 0)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.appOnSecondaryContainer.opacity(0.70))

        CardPreviewContent(payload: draft.previewPayload, presentation: .draftSummary)

        Spacer(minLength: 0)

        Text(draft.createdAt, format: .dateTime.hour().minute())
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.appOnSecondaryContainer.opacity(0.56))
      }
    }
  }
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

    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
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

private extension PHAsset {
  var pixelSize: CGSize {
    CGSize(width: pixelWidth, height: pixelHeight)
  }
}

private extension CMTime {
  var safeSeconds: TimeInterval {
    seconds.isFinite ? seconds : 0
  }
}

/// Bottom action row for building and posting a thread.
///
/// Owns the `canSave` check so card payload changes are observed *here* rather
/// than in `CreationView.body` — editing one detail screen only re-renders this
/// row and the affected card summary, not the whole compose screen.
private struct ThreadDraftActionRow: View {

  let draftCards: [ThreadDraftCard]
  let isSaving: Bool
  let onComposeText: @MainActor @Sendable () -> Void
  let onComposeLink: @MainActor @Sendable () -> Void
  let onCapturePhoto: @MainActor @Sendable () -> Void
  let onChooseMediaFromLibrary: @MainActor @Sendable (PhotosPickerItem) -> Void
  let onMediaPickerUnavailable: @MainActor @Sendable () -> Void
  let onDrawDoodle: @MainActor @Sendable () -> Void
  let onComposeBauhaus: @MainActor @Sendable () -> Void
  let onRecordVoice: @MainActor @Sendable () -> Void
  let onSave: @MainActor @Sendable () -> Void

  private var canSave: Bool {
    guard draftCards.isEmpty == false else {
      return false
    }

    return draftCards.allSatisfy {
      $0.canSave
    }
  }

  var body: some View {
    HStack {
      ScrollView(.horizontal) {
        GlassEffectContainer(spacing: 12) {
          HStack(spacing: 12) {
            ThreadDraftContentActionGroup(
              onComposeText: onComposeText,
              onComposeLink: onComposeLink,
              onCapturePhoto: onCapturePhoto,
              onChooseMediaFromLibrary: onChooseMediaFromLibrary,
              onMediaPickerUnavailable: onMediaPickerUnavailable,
              onDrawDoodle: onDrawDoodle,
              onComposeBauhaus: onComposeBauhaus,
              onRecordVoice: onRecordVoice
            )
            .disabled(isSaving)
            .opacity(isSaving ? 0.45 : 1)

            Spacer(minLength: 0)
          }
        }
      }
      .scrollClipDisabled()
      .scrollIndicators(.hidden)

      Button(action: onSave) {
        Text("Save")
          .foregroundStyle(.appOnTint)
      }
      .controlSize(.large)
      .buttonStyle(.glass(.regular.tint(.accentColor).interactive()))
      .disabled(canSave == false || isSaving)
      .accessibilityLabel("Post Thread")

    }
  }

  /// Separated Liquid Glass buttons for choosing the next content type.
  private struct ThreadDraftContentActionGroup: View {

    let onComposeText: @MainActor @Sendable () -> Void
    let onComposeLink: @MainActor @Sendable () -> Void
    let onCapturePhoto: @MainActor @Sendable () -> Void
    let onChooseMediaFromLibrary: @MainActor @Sendable (PhotosPickerItem) -> Void
    let onMediaPickerUnavailable: @MainActor @Sendable () -> Void
    let onDrawDoodle: @MainActor @Sendable () -> Void
    let onComposeBauhaus: @MainActor @Sendable () -> Void
    let onRecordVoice: @MainActor @Sendable () -> Void

    @State private var selectedLibraryMediaItem: PhotosPickerItem?
    @State private var isLibraryMediaPickerPresented = false

    var body: some View {
      HStack(spacing: 12) {
        ThreadDraftActionIconButton(
          systemName: "text.alignleft",
          accessibilityLabel: "Text",
          action: onComposeText
        )

        ThreadDraftActionIconButton(
          systemName: "link",
          accessibilityLabel: "Link",
          action: onComposeLink
        )

        ThreadDraftActionIconButton(
          systemName: "camera",
          accessibilityLabel: "Photo",
          action: onCapturePhoto
        )

        Button {
          presentLibraryMediaPicker()
        } label: {
          ThreadDraftActionIconLabel(systemName: "photo.on.rectangle.angled")
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityLabel(Text("Choose Media"))
        .photosPicker(
          isPresented: $isLibraryMediaPickerPresented,
          selection: $selectedLibraryMediaItem,
          matching: .any(of: [.images, .livePhotos, .videos]),
          preferredItemEncoding: .current,
          photoLibrary: .shared()
        )
        .onChange(of: selectedLibraryMediaItem) { _, item in
          guard let item else { return }
          selectedLibraryMediaItem = nil
          onChooseMediaFromLibrary(item)
        }

        ThreadDraftActionIconButton(
          systemName: "scribble.variable",
          accessibilityLabel: "Doodle",
          action: onDrawDoodle
        )

        ThreadDraftActionIconButton(
          systemName: "square.grid.3x3.square",
          accessibilityLabel: "Bauhaus",
          action: onComposeBauhaus
        )

        ThreadDraftActionIconButton(
          systemName: "waveform",
          accessibilityLabel: "Voice",
          action: onRecordVoice
        )
      }
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
          onMediaPickerUnavailable()
        }
      }
    }

    /// Shared visual payload for icon-only compose controls.
    private struct ThreadDraftActionIconLabel: View {

      let systemName: String

      var body: some View {
        Image(systemName: systemName)
          .font(.system(size: 18, weight: .semibold))
          .foregroundStyle(.appOnSecondaryContainer)
          .frame(width: 52, height: 42)
          .contentShape(Capsule())
      }
    }

    /// Compact icon button for the compose action row.
    private struct ThreadDraftActionIconButton: View {

      let systemName: String
      let accessibilityLabel: LocalizedStringResource
      let action: @MainActor @Sendable () -> Void

      var body: some View {
        Button(action: action) {
          ThreadDraftActionIconLabel(systemName: systemName)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityLabel(Text(accessibilityLabel))
      }
    }

  }

}

extension Card.Kind {

  /// User-facing name for the editor modality.
  var displayTitle: LocalizedStringResource {
    switch self {
    case .text:
      return "Text"
    case .link:
      return "Link"
    case .photo:
      return "Photo"
    case .video:
      return "Video"
    case .livePhoto:
      return "Live Photo"
    case .audio:
      return "Audio"
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

  /// SF Symbol representing this card kind in compose and editor chrome.
  var creationSymbolName: String {
    switch self {
    case .text:
      return "text.alignleft"
    case .link:
      return "link"
    case .photo:
      return "camera"
    case .video:
      return "video"
    case .livePhoto:
      return "livephoto"
    case .audio:
      return "waveform"
    case .doodle:
      return "scribble.variable"
    case .bauhaus:
      return "square.grid.3x3.square"
    case .unknown:
      return "questionmark"
    @unknown default:
      return "questionmark"
    }
  }
}
