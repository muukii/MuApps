import Algorithms
import CoreLocation
import CaptureAudio
import CaptureDoodle
import CapturePhoto
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

  @State private var draftCards: [ThreadDraftCard] = [ThreadDraftCard()]
  @State private var presentedDraft: ThreadDraftCard?
  @State private var voiceRecorderPresentation: VoiceRecorderPresentation?
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
                onAddCard: {
                  addDraftCard()
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
    .fullScreenCover(item: $presentedDraft) { presentedDraft in
      NavigationStack {
        ThreadDraftCardDetailEditor(
          card: presentedDraft,
          isSaving: isSaving,
          onToggleLocation: {
            toggleLocation(presentedDraft)
          }
        )
      }
      .navigationTransition(.zoom(sourceID: presentedDraft, in: namespace))
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
    }
    .sheet(isPresented: $isSettingsPresented) {
      SettingsScreen()
        .navigationTransition(.zoom(sourceID: "settings", in: namespace))
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

  private func addDraftCard() {
    let draft = ThreadDraftCard()
    draftCards.append(draft)
    scrollTargetID = draft
    presentEditor(for: draft)
  }

  private func openDraft(_ draft: ThreadDraftCard) {
    switch draft.kind {
    case .audio:
      voiceRecorderPresentation = VoiceRecorderPresentation(target: draft)
    case .text, .photo, .doodle:
      presentEditor(for: draft)
    @unknown default:
      presentEditor(for: draft)
    }
  }

  private func presentEditor(for draft: ThreadDraftCard) {
    presentedDraft = draft
  }

  private func presentVoiceRecorder() {
    voiceRecorderPresentation = VoiceRecorderPresentation(target: nil)
  }

  private func finishVoiceRecording(_ recording: AudioRecording, target: ThreadDraftCard?) {
    let draft = target ?? draftForNewVoiceRecording()
    draft.setAudio(recording)
    scrollTargetID = draft
  }

  private func draftForNewVoiceRecording() -> ThreadDraftCard {
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
        presentedDraft = nil
        // The store the widget reads just changed; ask WidgetKit to rebuild its
        // timeline so the "Latest Note" widget shows what was just written.
        WidgetCenter.shared.reloadAllTimelines()
      } catch {
        // TODO: surface the failure once the creation flow is designed. The draft
        // is left on screen so nothing the user typed is lost.
      }
    }
  }

}

/// Presentation payload for the recorder sheet.
private struct VoiceRecorderPresentation: Identifiable {

  /// A stable identity for one sheet presentation. Reopening the same card gets
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
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
  let onAddCard: @MainActor @Sendable () -> Void
  let onRecordVoice: @MainActor @Sendable () -> Void
  let onSave: @MainActor @Sendable () -> Void

  private var canSave: Bool {
    draftCards.allSatisfy {
      $0.canSave
    }
  }

  var body: some View {
    HStack(spacing: 16) {
      Button(action: onAddCard) {
        Label("Add Card", systemImage: "plus")
      }
      .buttonStyle(.glass)
      .disabled(isSaving)

      Button(action: onRecordVoice) {
        Label("Voice Record", systemImage: "waveform")
      }
      .buttonStyle(.glass)
      .disabled(isSaving)

      Spacer(minLength: 0)

      Button(action: onSave) {
        Image(systemName: "arrow.up")
          .resizable()
          .frame(width: 24, height: 24)
          .padding(2)
          .padding(.vertical, 5)
          .contentShape(Circle())
      }
      .buttonStyle(.glassProminent)
      .disabled(canSave == false || isSaving)
      .accessibilityLabel("Post Thread")
    }
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
    @unknown default:
      return "questionmark"
    }
  }
}
