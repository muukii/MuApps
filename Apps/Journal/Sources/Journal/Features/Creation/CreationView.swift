import CaptureAudio
import CaptureBauhaus
import CaptureDoodle
import CapturePhoto
import CoreLocation
import JournalVault
import MuColor
import PhotosUI
import ScrollEdgeEffect
import SwiftUI
import UIKit
import WidgetKit

struct CreationView: View {

  private let onChangeVault: (@MainActor @Sendable () -> Void)?

  @Environment(\.appPalette) private var palette
  @Environment(\.colorScheme) private var colorScheme
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
  @State private var isImportingPhotoFromLibrary: Bool = false
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
              Label(vaultRuntime.selectedVault?.title ?? "Vault", systemImage: "shippingbox")
            }
            .accessibilityLabel("Change Vault")
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
          isSaving: isSaving || isImportingPhotoFromLibrary,
          onComposeText: {
            presentTextCapture()
          },
          onComposeLink: {
            presentLinkCapture()
          },
          onCapturePhoto: {
            presentPhotoCapture()
          },
          onChoosePhotoFromLibrary: { item in
            importPhotoFromLibrary(item)
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

  private func importPhotoFromLibrary(_ item: PhotosPickerItem) {
    guard isImportingPhotoFromLibrary == false else {
      return
    }

    isImportingPhotoFromLibrary = true

    Task { @MainActor in
      defer { isImportingPhotoFromLibrary = false }

      do {
        let photo = try await PhotoLibraryImport.capturedPhoto(from: item)
        finishPhotoCapture(photo, target: nil)
      } catch {
        notifications.post(.photoImportFailed)
      }
    }
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

        let vaultDrafts = try drafts.map {
          try $0.vaultDraft(
            palette: palette,
            colorScheme: colorScheme
          )
        }
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
    .accessibilityLabel("Edit card")
  }
}

/// Card-shaped summary for an unsaved draft.
///
/// This view intentionally knows only about `CardEditDraft` and capture payloads.
/// It does not bridge to legacy saved-entry rendering or any persistence model.
private struct DraftEntrySummaryCard: View {

  let draft: CardEditDraft

  @Environment(\.appPalette) private var palette
  @Environment(\.colorScheme) private var colorScheme

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

        summaryContent

        Spacer(minLength: 0)

        Text(draft.createdAt, format: .dateTime.hour().minute())
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.appOnSecondaryContainer.opacity(0.56))
      }
    }
  }

  @ViewBuilder
  private var summaryContent: some View {
    switch draft.kind {
    case .text:
      Text(draft.text.isEmpty ? "Text" : draft.text)
        .font(.headline.weight(.semibold))
        .lineLimit(8)
        .foregroundStyle(draft.text.isEmpty ? .secondary : .primary)
    case .link:
      if let linkURL = draft.linkURL {
        JournalLinkPreview(url: linkURL.url, mode: .summary)
      } else {
        Text(draft.text.isEmpty ? "Link" : draft.text)
          .font(.headline.weight(.semibold))
          .lineLimit(8)
          .foregroundStyle(draft.text.isEmpty ? .secondary : .primary)
      }
    case .photo:
      if let image = draft.photo.flatMap({ UIImage(data: $0.imageData) }) {
        Image(uiImage: image)
          .resizable()
          .scaledToFill()
          .aspectRatio(1, contentMode: .fit)
          .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
      } else {
        DraftMediaPlaceholder(systemImage: "photo")
      }
    case .audio:
      DraftAudioSummary()
    case .doodle:
      if let image = draft.doodle?
        .image(inkColor: palette.tint, scale: 1) {
        Image(uiImage: image)
          .resizable()
          .scaledToFit()
          .aspectRatio(CardMetrics.aspectRatio, contentMode: .fit)
      } else {
        DraftMediaPlaceholder(systemImage: "scribble")
      }
    case .bauhaus:
      if let image = draft.bauhaus?
        .image(colorScheme: colorScheme, size: CGSize(width: 512, height: 512)) {
        Image(uiImage: image)
          .resizable()
          .scaledToFit()
          .aspectRatio(1, contentMode: .fit)
      } else {
        DraftMediaPlaceholder(systemImage: "square.grid.3x3")
      }
    case .unknown:
      DraftMediaPlaceholder(systemImage: "questionmark.square.dashed")
    @unknown default:
      DraftMediaPlaceholder(systemImage: "questionmark.square.dashed")
    }
  }
}

private struct DraftMediaPlaceholder: View {

  let systemImage: String

  var body: some View {
    RoundedRectangle(cornerRadius: 12, style: .continuous)
      .fill(.appOnSecondaryContainer.opacity(0.08))
      .aspectRatio(1, contentMode: .fit)
      .overlay {
        Image(systemName: systemImage)
          .font(.system(size: 34, weight: .semibold))
          .foregroundStyle(.appOnSecondaryContainer.opacity(0.42))
      }
  }
}

private struct DraftAudioSummary: View {

  var body: some View {
    HStack(alignment: .center, spacing: 4) {
      ForEach(DraftAudioWaveformSample.samples) { sample in
        Capsule()
          .fill(.appOnSecondaryContainer.opacity(0.62))
          .frame(width: 4, height: sample.height)
      }
    }
    .frame(maxWidth: .infinity, minHeight: 68, alignment: .center)
  }
}

private struct DraftAudioWaveformSample: Identifiable {
  let id: Int
  let height: CGFloat

  static let samples: [DraftAudioWaveformSample] = [
    18, 30, 24, 42, 34, 58, 46, 70, 38, 54, 28, 44,
  ].enumerated().map { index, height in
    DraftAudioWaveformSample(id: index, height: CGFloat(height))
  }
}

/// Converts a user-selected Photos item into the same draft payload as camera
/// capture, keeping the composer persistence path source-agnostic.
private enum PhotoLibraryImport {

  @MainActor
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
}

/// Failure cases from importing one selected Photos image.
private enum PhotoLibraryImportError: Error {
  case missingImageData
  case undecodableImage
  case missingJPEGData
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
  let onChoosePhotoFromLibrary: @MainActor @Sendable (PhotosPickerItem) -> Void
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
              onChoosePhotoFromLibrary: onChoosePhotoFromLibrary,
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
    let onChoosePhotoFromLibrary: @MainActor @Sendable (PhotosPickerItem) -> Void
    let onDrawDoodle: @MainActor @Sendable () -> Void
    let onComposeBauhaus: @MainActor @Sendable () -> Void
    let onRecordVoice: @MainActor @Sendable () -> Void

    @State private var selectedLibraryPhotoItem: PhotosPickerItem?

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

        PhotosPicker(
          selection: $selectedLibraryPhotoItem,
          matching: .images,
          preferredItemEncoding: .compatible
        ) {
          ThreadDraftActionIconLabel(systemName: "photo.on.rectangle.angled")
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityLabel(Text("Choose Photo"))
        .onChange(of: selectedLibraryPhotoItem) { _, item in
          guard let item else { return }
          selectedLibraryPhotoItem = nil
          onChoosePhotoFromLibrary(item)
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
