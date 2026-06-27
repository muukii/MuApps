import Algorithms
import CaptureAudio
import CaptureBauhaus
import CaptureDoodle
import CapturePhoto
import CoreLocation
import JournalModel
import MuColor
import ScrollEdgeEffect
import SwiftData
import SwiftUI
import UIKit
import WidgetKit

struct CreationView: View {

  @Environment(\.modelContext) private var modelContext
  @Environment(\.openURL) private var openURL
  @Environment(\.appPalette) private var palette
  @Environment(JournalNotificationCenter.self) private var notifications

  @State private var draftCards: [ThreadDraftCard] = [ThreadDraftCard()]
  @State private var textEditorPresentation: TextEditorPresentation?
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
  @Namespace private var namespace

  /// Shared one-shot location bridge. Each draft card stores the resolved
  /// coordinate it wants to persist; this object only handles permission and
  /// the current coordinate lookup.
  @State private var locationManager = LocationManager()
  @State private var isLocationDeniedAlertPresented: Bool = false

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

            DateView()
              .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 20) {
              ForEach(draftCards.indexed(), id: \.element) {
                offset,
                draft in
                ThreadDraftCardEditor(
                  ordinal: offset + 1,
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

              ThreadDraftActionRow(
                draftCards: draftCards,
                isSaving: isSaving,
                onComposeText: {
                  presentTextCapture()
                },
                onCapturePhoto: {
                  presentPhotoCapture()
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
            }
            .scrollTargetLayout()
          }
          .padding(.horizontal, 16)
          .padding(.top, 16)
        }
        .scrollPosition(id: $scrollTargetID, anchor: .center)
        .scrollTargetBehavior(.viewAligned)

      }
      .toolbar(content: {
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
    }
    .sheet(item: $textEditorPresentation) { presentation in
      ThreadDraftTextEditorSheet(
        card: presentation.target,
        isSaving: isSaving,
        onToggleLocation: {
          toggleLocation(presentation.target)
        }
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
      .presentationDetents([.medium, .large], selection: $quickDoodleSheetDetent)
      .presentationDragIndicator(.visible)
      .presentationBackground(.background)
    }
    .sheet(item: $bauhausGridPresentation) { presentation in
      ThreadDraftBauhausGridSheet(
        card: presentation.target,
        onChange: { artwork in
          updateBauhaus(artwork, presentation: presentation)
        }
      )
      .presentationDetents([.medium, .large])
      .presentationDragIndicator(.visible)
      .presentationBackground(.background)
    }
    .sheet(item: $quickBauhausGridPresentation) { presentation in
      ThreadDraftBauhausGridSheet(
        card: presentation.target,
        onChange: { artwork in
          updateBauhaus(artwork, presentation: presentation)
        }
      )
      .presentationDetents([.medium, .large], selection: $quickBauhausSheetDetent)
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
    .appNavigationBarStyle()
    .onChange(of: locationManager.authorizationStatus) { _, status in
      // System access can be revoked after a coordinate was attached. Clear
      // draft coordinates so the UI never claims location metadata it can no
      // longer justify.
      switch status {
      case .denied, .restricted:
        for card in draftCards {
          card.location = nil
        }
      case .notDetermined, .authorizedWhenInUse, .authorizedAlways:
        break
      @unknown default:
        break
      }
    }
    .alert("Location Access Off", isPresented: $isLocationDeniedAlertPresented)
    {
      Button("Open Settings") {
        openLocationSettings()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "Allow location access in Settings to attach where you are to a card."
      )
    }

  }

  private func presentTextCapture() {
    if let draft = draftCards.last, draft.isEmptyTextDraft {
      scrollTargetID = draft
      presentTextEditor(for: draft)
      return
    }

    let draft = ThreadDraftCard()
    draftCards.append(draft)
    scrollTargetID = draft
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
    @unknown default:
      presentTextEditor(for: draft)
    }
  }

  private func presentTextEditor(for draft: ThreadDraftCard) {
    textEditorPresentation = TextEditorPresentation(target: draft)
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
    _ artwork: BauhausGridArtwork?,
    presentation: BauhausGridPresentation
  ) {
    guard let artwork, artwork.isEmpty == false else {
      clearBauhaus(for: presentation)
      return
    }

    let draft = presentation.target ?? draftForNewBauhausCapture(presentation)
    draft.setBauhaus(artwork)
    scrollTargetID = draft
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
  }

  private func draftForNewQuickCapture() -> ThreadDraftCard {
    if let draft = draftCards.last, draft.isEmptyTextDraft {
      return draft
    }

    let draft = ThreadDraftCard()
    draftCards.append(draft)
    return draft
  }

  /// Turns the per-card location attachment on or off. Enabling it captures the
  /// current coordinate immediately, so the draft owns the data it will save.
  private func toggleLocation(_ draft: ThreadDraftCard) {
    guard draft.location == nil else {
      draft.location = nil
      return
    }

    switch locationManager.authorizationStatus {
    case .authorizedWhenInUse, .authorizedAlways:
      requestLocation(for: draft)
    case .notDetermined:
      requestLocation(for: draft)
    case .denied, .restricted:
      isLocationDeniedAlertPresented = true
    @unknown default:
      isLocationDeniedAlertPresented = true
    }
  }

  private func requestLocation(for draft: ThreadDraftCard) {
    Task { @MainActor in
      guard let location = await locationManager.requestCoordinate() else {
        return
      }
      draft.location = location
    }
  }

  private func openLocationSettings() {
    guard let url = URL(string: UIApplication.openSettingsURLString) else {
      return
    }
    openURL(url)
  }

  private func save() {

    let drafts = draftCards.map { $0.savingSnapshot() }
    let doodleInkColor = palette.tint

    guard drafts.isEmpty == false, isSaving == false else { return }

    // Read the thread snapshot now so persistence works from the card payloads
    // the user had authored at the moment they tapped save.
    isSaving = true

    Task {
      defer { isSaving = false }

      do {
        let storeInputs = try drafts.map {
          try $0.storeInput(doodleInkColor: doodleInkColor)
        }
        try JournalStore.createThread(cards: storeInputs, in: modelContext)
        let nextDraft = ThreadDraftCard()
        draftCards = [nextDraft]
        textEditorPresentation = nil
        photoCapturePresentation = nil
        doodleCanvasPresentation = nil
        bauhausGridPresentation = nil
        voiceRecorderPresentation = nil
        quickDoodleCanvasPresentation = nil
        quickBauhausGridPresentation = nil
        // The store the widget reads just changed; ask WidgetKit to rebuild its
        // timeline so the "Latest Note" widget shows what was just written.
        WidgetCenter.shared.reloadAllTimelines()
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

  let ordinal: Int
  @Bindable var card: ThreadDraftCard
  let isSaving: Bool
  let onOpen: @MainActor @Sendable () -> Void

  var body: some View {
    Button(action: onOpen) {
      CardSurface {
        VStack(alignment: .leading, spacing: 12) {
          ThreadDraftCardHeader(
            ordinal: ordinal,
            kind: card.kind,
            location: card.location
          )

          ThreadDraftCardPreview(card: card)
            .frame(
              maxWidth: .infinity,
              maxHeight: .infinity,
              alignment: .topLeading
            )
        }
      }
    }
    .buttonStyle(.plain)
    .disabled(isSaving)
    .accessibilityLabel("Edit card \(ordinal)")
  }
}

/// Compact metadata row shown at the top of a draft card.
private struct ThreadDraftCardHeader: View {

  let ordinal: Int
  let kind: Card.Kind
  let location: Coordinate?

  var body: some View {
    HStack(spacing: 10) {
      Text("Card \(ordinal)")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.appOnSecondaryContainer.opacity(0.55))

      Label {
        Text(kind.displayTitle)
      } icon: {
        Image(systemName: kind.creationSymbolName)
      }
      .font(.caption.weight(.semibold))
      .labelStyle(.titleAndIcon)
      .padding(.horizontal, 8)
      .padding(.vertical, 5)
      .background(.appOnSecondaryContainer.opacity(0.08), in: Capsule())

      Spacer(minLength: 0)

      if location != nil {
        Image(systemName: "location.fill")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.appOnSecondaryContainer.opacity(0.55))
          .accessibilityLabel("Location attached")
      }

      Image(systemName: "chevron.right")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.appOnSecondaryContainer.opacity(0.45))
    }
  }
}

/// Kind-aware summary of a draft card's current editable payload.
private struct ThreadDraftCardPreview: View {

  @Environment(\.appPalette) private var palette
  @Bindable var card: ThreadDraftCard

  var body: some View {
    switch card.kind {
    case .text:
      ThreadDraftTextPreview(text: card.text)
    case .photo:
      ThreadDraftMediaPreview(
        symbolName: card.kind.creationSymbolName,
        prompt: "Open camera",
        image: card.photo?.image
      )
    case .audio:
      ThreadDraftAudioPreview(duration: card.audio?.duration)
    case .doodle:
      ThreadDraftMediaPreview(
        symbolName: card.kind.creationSymbolName,
        prompt: "Open canvas",
        image: card.doodle?.image(inkColor: palette.tint)
      )
    case .bauhaus:
      ThreadDraftMediaPreview(
        symbolName: card.kind.creationSymbolName,
        prompt: "Open grid",
        image: card.bauhaus?.image()
      )
    @unknown default:
      ThreadDraftTextPreview(text: card.text)
    }
  }
}

/// Text-card summary for the creation surface.
private struct ThreadDraftTextPreview: View {

  let text: String

  var body: some View {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    Text(trimmed.isEmpty ? "Write your thoughts..." : trimmed)
      .font(.system(size: 32, weight: .bold))
      .foregroundStyle(.appOnSecondaryContainer)
      .opacity(trimmed.isEmpty ? 0.42 : 1)
      .lineLimit(7)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// Photo and doodle summary for the creation surface.
private struct ThreadDraftMediaPreview: View {

  let symbolName: String
  let prompt: LocalizedStringResource
  let image: UIImage?

  var body: some View {
    if let image {
      Image(uiImage: image)
        .resizable()
        .scaledToFill()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    } else {
      VStack(alignment: .leading, spacing: 10) {
        Image(systemName: symbolName)
          .font(.system(size: 42, weight: .semibold))
        Text(prompt)
          .font(.title3.weight(.semibold))
      }
      .foregroundStyle(.appOnSecondaryContainer.opacity(0.48))
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
  }
}

/// Audio-card summary for the creation surface.
private struct ThreadDraftAudioPreview: View {

  let duration: TimeInterval?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Image(systemName: "waveform")
        .font(.system(size: 46, weight: .semibold))

      if let duration {
        Text("Recorded \(Self.formatted(duration))")
          .font(.title3.weight(.semibold))
      } else {
        Text("Open recorder")
          .font(.title3.weight(.semibold))
      }
    }
    .foregroundStyle(.appOnSecondaryContainer)
    .opacity(duration == nil ? 0.48 : 0.86)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
  }

  private static func formatted(_ duration: TimeInterval) -> String {
    let total = Int(duration)
    return String(format: "%02d:%02d", total / 60, total % 60)
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
  let onCapturePhoto: @MainActor @Sendable () -> Void
  let onDrawDoodle: @MainActor @Sendable () -> Void
  let onComposeBauhaus: @MainActor @Sendable () -> Void
  let onRecordVoice: @MainActor @Sendable () -> Void
  let onSave: @MainActor @Sendable () -> Void

  private var canSave: Bool {
    draftCards.allSatisfy {
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
              onCapturePhoto: onCapturePhoto,
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
}

/// Separated Liquid Glass buttons for choosing the next content type.
private struct ThreadDraftContentActionGroup: View {

  let onComposeText: @MainActor @Sendable () -> Void
  let onCapturePhoto: @MainActor @Sendable () -> Void
  let onDrawDoodle: @MainActor @Sendable () -> Void
  let onComposeBauhaus: @MainActor @Sendable () -> Void
  let onRecordVoice: @MainActor @Sendable () -> Void

  var body: some View {
    HStack(spacing: 12) {
      ThreadDraftActionIconButton(
        systemName: "text.alignleft",
        accessibilityLabel: "Text",
        action: onComposeText
      )

      ThreadDraftActionIconButton(
        systemName: "camera",
        accessibilityLabel: "Photo",
        action: onCapturePhoto
      )

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
}

/// Compact icon button for the compose action row.
private struct ThreadDraftActionIconButton: View {

  let systemName: String
  let accessibilityLabel: LocalizedStringResource
  let action: @MainActor @Sendable () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: systemName)
        .font(.system(size: 18, weight: .semibold))
        .foregroundStyle(.appOnSecondaryContainer)
        .frame(width: 52, height: 42)
        .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .glassEffect(.regular.interactive(), in: .capsule)
    .accessibilityLabel(Text(accessibilityLabel))
  }
}

extension Card.Kind {

  /// User-facing name for the editor modality.
  var displayTitle: LocalizedStringResource {
    switch self {
    case .text:
      return "Text"
    case .photo:
      return "Photo"
    case .audio:
      return "Audio"
    case .doodle:
      return "Doodle"
    case .bauhaus:
      return "Bauhaus"
    @unknown default:
      return "Card"
    }
  }

  /// SF Symbol representing this card kind in compose and editor chrome.
  var creationSymbolName: String {
    switch self {
    case .text:
      return "text.alignleft"
    case .photo:
      return "camera"
    case .audio:
      return "waveform"
    case .doodle:
      return "scribble.variable"
    case .bauhaus:
      return "square.grid.3x3.square"
    @unknown default:
      return "questionmark"
    }
  }
}
