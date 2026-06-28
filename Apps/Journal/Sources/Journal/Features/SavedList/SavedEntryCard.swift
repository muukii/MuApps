import AVFoundation
import CaptureAudio
import CaptureBauhaus
import CaptureDoodle
import CapturePhoto
import Combine
import JournalModel
import MuColor
import Observation
import SwiftData
import SwiftUI
import UIKit
import WidgetKit

/// Maximum absolute tilt for a card, in degrees. Each tile picks a stable angle
/// in `-cardMaxTilt ... +cardMaxTilt` from its id, giving the grid a loosely
/// hand-placed feel rather than a rigid one.
private let cardMaxTilt: Double = 3

/// Outer inset for the pushed entry detail screen.
private let detailScreenPadding: CGFloat = 16

/// Largest width for the pushed detail card before the surrounding screen adds
/// empty margins. The card itself still keeps `CardSurface`'s paper aspect ratio.
private let detailMaximumCardWidth: CGFloat = 520

/// Corner radius for large media wells inside the detail card.
private let detailImageCornerRadius: CGFloat = 14

/// Detail screen for one saved entry.
///
/// The screen owns navigation chrome and actions; the actual card body is a
/// separate detail component so grid summaries can evolve independently. This
/// view deliberately keeps the live SwiftData `Card` at the screen boundary, so
/// record or relationship imports can recompute display values instead of
/// freezing a navigation-time snapshot.
struct SavedEntryDetailView: View {

  @Environment(\.modelContext) private var modelContext

  let card: Card
  let onShare: @MainActor (Card) -> Void

  @State private var editDraft: CardEditDraft?
  @State private var isEditDraftLoading = false
  @State private var isSavingEdit = false
  @State private var editErrorMessage: String?

  var body: some View {
    ScrollView {
      SavedEntryCard(presentation: .detail(card.detailDisplay))
        .frame(maxWidth: detailMaximumCardWidth)
        .frame(maxWidth: .infinity)
        .padding(detailScreenPadding)
    }
    .background(.background)
    .navigationTitle("Entry")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItemGroup(placement: .topBarTrailing) {
        Button {
          presentEditDraft()
        } label: {
          if isEditDraftLoading {
            ProgressView()
              .controlSize(.small)
          } else {
            Image(systemName: "square.and.pencil")
          }
        }
        .disabled(isEditDraftLoading || isSavingEdit)
        .accessibilityLabel("Edit")

        Button {
          onShare(card)
        } label: {
          Image(systemName: "square.and.arrow.up")
        }
        .accessibilityLabel("Share")
      }
    }
    .sheet(item: $editDraft) { draft in
      SavedEntryEditSheet(
        draft: draft,
        isSaving: isSavingEdit,
        onSave: {
          saveEdit(draft)
        },
        onCancel: {
          editDraft = nil
        }
      )
      .presentationBackground(.background)
    }
    .alert("Could Not Edit Entry", isPresented: editErrorPresentation) {
      Button("OK", role: .cancel) {}
    } message: {
      if let editErrorMessage {
        Text(editErrorMessage)
      }
    }
  }

  private var editErrorPresentation: Binding<Bool> {
    Binding {
      editErrorMessage != nil
    } set: { isPresented in
      if isPresented == false {
        editErrorMessage = nil
      }
    }
  }

  private func presentEditDraft() {
    guard isEditDraftLoading == false else { return }

    isEditDraftLoading = true
    Task { @MainActor in
      defer { isEditDraftLoading = false }

      do {
        editDraft = try await card.editDraft()
      } catch {
        editErrorMessage = error.localizedDescription
      }
    }
  }

  private func saveEdit(_ draft: CardEditDraft) {
    guard isSavingEdit == false else { return }

    isSavingEdit = true

    Task { @MainActor in
      defer { isSavingEdit = false }

      do {
        let input = try draft.savingSnapshot().storeInput()
        let result = try JournalStore.updateCard(card, with: input, in: modelContext)
        await MediaSyncEngine.shared.enqueueUploads(attachmentIDs: result.uploadedAttachmentIDs)
        for attachmentID in result.deletedAttachmentIDs {
          await MediaSyncEngine.shared.enqueueDelete(attachmentID: attachmentID)
        }
        WidgetCenter.shared.reloadTimelines(ofKind: JournalWidgetKind.latestNote)
        editDraft = nil
      } catch {
        editErrorMessage = error.localizedDescription
      }
    }
  }
}

/// Modal editor for an existing saved entry.
///
/// The sheet owns cancellation chrome while `CardEditDraftEditor` owns the
/// actual card-editing controls. Saving is still lifted to the detail screen so
/// SwiftData, media sync, and widget reloads stay at the live model boundary.
private struct SavedEntryEditSheet: View {

  @Bindable var draft: CardEditDraft
  let isSaving: Bool
  let onSave: @MainActor () -> Void
  let onCancel: @MainActor () -> Void

  var body: some View {
    NavigationStack {
      CardEditDraftEditor(
        draft: draft,
        isSaving: isSaving,
        confirmationTitle: "Save",
        showsKindPicker: false,
        onConfirm: onSave
      )
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            onCancel()
          }
          .disabled(isSaving)
        }
      }
    }
  }
}

/// Observation boundary for one SwiftData-backed entry tile.
///
/// The pure card below still receives a short-lived display value, but that value
/// is derived inside this view's body from the live `Card`. This keeps row UI on
/// SwiftData observation when `Attachment` rows arrive or card fields change.
struct SavedEntrySummaryCardHost: View {

  let card: Card

  var body: some View {
    SavedEntryCard(presentation: .summary(card.summaryDisplay))
  }
}

/// Entry-style summary card for an unsaved draft on the creation surface.
///
/// This keeps `CreationView` on the same card component as saved entries while
/// still feeding it the draft's in-memory capture payloads.
struct DraftEntrySummaryCard: View {

  @Bindable var draft: CardEditDraft

  var body: some View {
    SavedEntryCard(presentation: .summary(draft.summaryDisplay))
  }
}

/// Adaptive card wrapper for saved entries.
///
/// This is the single component that owns `CardSurface`, so the paper aspect
/// ratio, fill, corner radius, and inset stay consistent. The presentation only
/// chooses which internal layout renders inside that invariant card shell.
private struct SavedEntryCard: View {

  let presentation: SavedEntryCardPresentation

  var body: some View {
    CardSurface {
      content
    }
    .rotationEffect(presentation.rotation)
    .modifier(SavedEntryCardAccessibilityModifier(isSummary: presentation.isSummary))
  }

  @ViewBuilder
  private var content: some View {
    switch presentation {
    case .summary(let display):
      SavedEntrySummaryCardLayout(display: display)
    case .detail(let display):
      SavedEntryDetailCardLayout(display: display)
    }
  }
}

/// Summary or detail presentation for the adaptive saved-entry card wrapper.
private enum SavedEntryCardPresentation {
  case summary(SavedEntrySummaryDisplay)
  case detail(SavedEntryDetailDisplay)

  var rotation: Angle {
    switch self {
    case .summary(let display):
      return display.tilt
    case .detail:
      return .zero
    }
  }

  var isSummary: Bool {
    switch self {
    case .summary:
      return true
    case .detail:
      return false
    }
  }
}

/// Applies the right accessibility grouping for each card presentation.
private struct SavedEntryCardAccessibilityModifier: ViewModifier {

  let isSummary: Bool

  func body(content: Content) -> some View {
    if isSummary {
      content.accessibilityElement(children: .combine)
    } else {
      content.accessibilityElement(children: .contain)
    }
  }
}

/// Compact grid layout inside `SavedEntryCard`.
///
/// This component intentionally keeps the dense-list behavior: clipped media
/// previews and short text. The wrapper owns paper chrome and tilt.
private struct SavedEntrySummaryCardLayout: View {

  let display: SavedEntrySummaryDisplay

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      SavedEntrySummaryCardContent(content: display.content)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

      SavedEntrySummaryCardFooter(createdAt: display.createdAt, kind: display.content.kind)
    }
  }
}

/// Context actions for one saved-entry summary card.
struct SavedEntrySummaryCardContextMenu: View {

  let card: Card
  let onShare: @MainActor (Card) -> Void

  var body: some View {
    Button {
      onShare(card)
    } label: {
      Label("Share", systemImage: "square.and.arrow.up")
    }
  }
}

/// The modality-specific body of a summary card.
///
/// Summary content is optimized for scanability in a grid and should not inherit
/// detail-only affordances such as full text or audio controls.
private struct SavedEntrySummaryCardContent: View {

  let content: SavedEntryCardContent

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      switch content {
      case .text(let text):
        Group {
          if text.isEmpty {
            Text("Untitled")
          } else {
            Text(text)
          }
        }
        .font(.callout)
        .lineLimit(9)
        .multilineTextAlignment(.leading)
        .minimumScaleFactor(0.9)
        .frame(maxWidth: .infinity, alignment: .leading)
      case .audio:
        SavedEntrySummaryAudioContent()
      case .image(let asset):
        SavedEntrySummaryImageContent(asset: asset)
      case .capturedImage(let image):
        SavedEntrySummaryCapturedImageContent(image: image)
      case .doodle(let asset):
        SavedEntrySummaryDoodleContent(asset: asset)
      case .capturedDoodle(let drawing):
        SavedEntrySummaryCapturedDoodleContent(drawing: drawing)
      case .bauhaus(let asset):
        SavedEntrySummaryBauhausContent(asset: asset)
      case .capturedBauhaus(let document):
        SavedEntrySummaryCapturedBauhausContent(document: document)
      case .unknown:
        SavedEntryUnknownContent()
      }
    }
  }
}

/// Footer shared by every summary card: timestamp plus the card's modality icon.
private struct SavedEntrySummaryCardFooter: View {

  let createdAt: Date
  let kind: Card.Kind

  var body: some View {
    HStack(spacing: 6) {
      Text(createdAt, format: .relative(presentation: .named))
        .lineLimit(1)

      Spacer(minLength: 0)

      Image(systemName: kind.symbolName)
    }
    .font(.caption2)
    .foregroundStyle(.appOnSecondaryContainer.opacity(0.55))
  }
}

/// Text-free audio summary content.
private struct SavedEntrySummaryAudioContent: View {

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      ZStack {
        Circle()
          .fill(.appOnSecondaryContainer.opacity(0.08))
          .frame(width: 44, height: 44)

        Image(systemName: "waveform")
          .font(.system(size: 22, weight: .semibold))
          .foregroundStyle(.appOnSecondaryContainer.opacity(0.78))
      }

      SavedEntryAudioWaveform()
        .frame(height: 56)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}

/// Placeholder body for a card whose modality this build does not recognize
/// (for example one synced from a newer app version). Shared by summary and
/// detail so an unsupported card reads the same wherever it appears.
private struct SavedEntryUnknownContent: View {

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      ZStack {
        Circle()
          .fill(.appOnSecondaryContainer.opacity(0.08))
          .frame(width: 44, height: 44)

        Image(systemName: "questionmark")
          .font(.system(size: 22, weight: .semibold))
          .foregroundStyle(.appOnSecondaryContainer.opacity(0.78))
      }

      Text("This card was made in a newer version and can't be shown here yet.")
        .font(.callout)
        .foregroundStyle(.appOnSecondaryContainer.opacity(0.62))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}

/// Static waveform skeleton for audio-only cards.
///
/// Fixed sample ids keep summary/detail identity stable across body evaluations.
private struct SavedEntryAudioWaveform: View {

  let barWidth: CGFloat
  let minimumHeight: CGFloat
  let maximumAddedHeight: CGFloat
  let opacity: Double

  init(
    barWidth: CGFloat = 4,
    minimumHeight: CGFloat = 10,
    maximumAddedHeight: CGFloat = 42,
    opacity: Double = 0.34
  ) {
    self.barWidth = barWidth
    self.minimumHeight = minimumHeight
    self.maximumAddedHeight = maximumAddedHeight
    self.opacity = opacity
  }

  private static let samples: [SavedEntryAudioWaveformSample] = [
    .init(id: 0, level: 0.24),
    .init(id: 1, level: 0.55),
    .init(id: 2, level: 0.36),
    .init(id: 3, level: 0.82),
    .init(id: 4, level: 0.48),
    .init(id: 5, level: 0.68),
    .init(id: 6, level: 0.31),
    .init(id: 7, level: 0.74),
    .init(id: 8, level: 0.42),
    .init(id: 9, level: 0.58),
    .init(id: 10, level: 0.28),
    .init(id: 11, level: 0.46),
  ]

  var body: some View {
    HStack(alignment: .center, spacing: 4) {
      ForEach(Self.samples) { sample in
        Capsule()
          .fill(.appOnSecondaryContainer.opacity(opacity))
          .frame(width: barWidth, height: minimumHeight + sample.level * maximumAddedHeight)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
  }
}

/// One deterministic waveform bar.
private struct SavedEntryAudioWaveformSample: Identifiable {
  let id: Int
  let level: CGFloat
}

/// Photo cards resolve their saved media file asynchronously for the visual body.
private struct SavedEntrySummaryImageContent: View {

  let asset: SavedEntryMediaAsset<SavedEntryPhotoMediaLoader>?

  var body: some View {
    SavedEntryMediaContentView(
      asset: asset,
      fallbackSymbolName: "photo",
      cornerRadius: 10,
      fallbackFontSize: 34
    ) { image in
      SavedEntryLoadedPhotoView(
        image: image,
        contentMode: .fill,
        imagePadding: 0
      )
    }
    .aspectRatio(4 / 3, contentMode: .fit)
  }
}

/// Photo summary content for an unsaved draft payload.
private struct SavedEntrySummaryCapturedImageContent: View {

  let image: UIImage?

  var body: some View {
    SavedEntryInlineMediaContentView(
      payload: image,
      fallbackSymbolName: "photo",
      cornerRadius: 10,
      fallbackFontSize: 34
    ) { image in
      SavedEntryLoadedPhotoView(
        image: image,
        contentMode: .fill,
        imagePadding: 0
      )
    }
    .aspectRatio(4 / 3, contentMode: .fit)
  }
}

/// Doodle cards preserve the drawing as an object on the paper, not as a captioned
/// note. The saved vector payload is decoded and rendered as a SwiftUI view.
private struct SavedEntrySummaryDoodleContent: View {

  @Environment(\.appPalette) private var palette

  let asset: SavedEntryMediaAsset<SavedEntryDoodleMediaLoader>?

  var body: some View {
    SavedEntryMediaContentView(
      asset: asset,
      fallbackSymbolName: "scribble.variable",
      cornerRadius: 10,
      fallbackFontSize: 34
    ) { drawing in
      DoodleDrawingView(
        drawing: drawing,
        inkColor: palette.tint,
        displayAspectRatio: CardMetrics.aspectRatio
      )
      .padding(12)
    }
    .aspectRatio(CardMetrics.aspectRatio, contentMode: .fit)
  }
}

/// Doodle summary content for an unsaved draft payload.
private struct SavedEntrySummaryCapturedDoodleContent: View {

  @Environment(\.appPalette) private var palette

  let drawing: DoodleDrawing?

  var body: some View {
    SavedEntryInlineMediaContentView(
      payload: drawing,
      fallbackSymbolName: "scribble.variable",
      cornerRadius: 10,
      fallbackFontSize: 34
    ) { drawing in
      DoodleDrawingView(
        drawing: drawing,
        inkColor: palette.tint,
        displayAspectRatio: CardMetrics.aspectRatio
      )
      .padding(12)
    }
    .aspectRatio(CardMetrics.aspectRatio, contentMode: .fit)
  }
}

/// Bauhaus cards render the decoded grid as live SwiftUI content.
private struct SavedEntrySummaryBauhausContent: View {

  let asset: SavedEntryMediaAsset<SavedEntryBauhausMediaLoader>?

  var body: some View {
    SavedEntryMediaContentView(
      asset: asset,
      fallbackSymbolName: "square.grid.3x3.square",
      cornerRadius: 10,
      fallbackFontSize: 34
    ) { document in
      BauhausGridArtworkView(artwork: document.artwork)
        .padding(12)
    }
    .aspectRatio(4 / 3, contentMode: .fit)
  }
}

/// Bauhaus summary content for an unsaved draft payload.
private struct SavedEntrySummaryCapturedBauhausContent: View {

  let document: BauhausGridDocument?

  var body: some View {
    SavedEntryInlineMediaContentView(
      payload: document,
      fallbackSymbolName: "square.grid.3x3.square",
      cornerRadius: 10,
      fallbackFontSize: 34
    ) { document in
      BauhausGridArtworkView(artwork: document.artwork)
        .padding(12)
    }
    .aspectRatio(4 / 3, contentMode: .fit)
  }
}

/// Synchronous media well for unsaved draft payloads.
private struct SavedEntryInlineMediaContentView<
  Payload,
  LoadedContent: View
>: View {

  let payload: Payload?
  let fallbackSymbolName: String
  let cornerRadius: CGFloat
  let fallbackFontSize: CGFloat
  let loadedContent: (Payload) -> LoadedContent

  init(
    payload: Payload?,
    fallbackSymbolName: String,
    cornerRadius: CGFloat,
    fallbackFontSize: CGFloat,
    @ViewBuilder loadedContent: @escaping (Payload) -> LoadedContent
  ) {
    self.payload = payload
    self.fallbackSymbolName = fallbackSymbolName
    self.cornerRadius = cornerRadius
    self.fallbackFontSize = fallbackFontSize
    self.loadedContent = loadedContent
  }

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        .fill(.appOnSecondaryContainer.opacity(0.06))

      if let payload {
        loadedContent(payload)
      } else {
        Image(systemName: fallbackSymbolName)
          .font(.system(size: fallbackFontSize, weight: .semibold))
          .foregroundStyle(.appOnSecondaryContainer.opacity(0.46))
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        .strokeBorder(.appOnSecondaryContainer.opacity(0.08), lineWidth: 1)
    }
  }
}

/// Async media well for saved attachments.
///
/// The saved entry display model carries an asset reference instead of a SwiftUI
/// `Image`, so photo bytes and editable vector payloads can be loaded only when
/// a card is actually on screen.
private struct SavedEntryMediaContentView<
  Loader: SavedEntryMediaLoading,
  LoadedContent: View
>: View {

  @Environment(\.appPalette) private var palette
  @State private var phase: SavedEntryMediaLoadPhase<Loader.Payload> = .idle

  /// Bumped when `MediaSyncEngine` writes the same attachment file path later.
  ///
  /// CKAsset files can arrive after SwiftData has already delivered the
  /// `Attachment` row, so the URL may stay identical while its contents become
  /// available. Including this value in the task identity retries that load.
  @State private var reloadRevision = 0

  let asset: SavedEntryMediaAsset<Loader>?
  let fallbackSymbolName: String
  let cornerRadius: CGFloat
  let fallbackFontSize: CGFloat
  let loadedContent: (Loader.Payload) -> LoadedContent

  init(
    asset: SavedEntryMediaAsset<Loader>?,
    fallbackSymbolName: String,
    cornerRadius: CGFloat,
    fallbackFontSize: CGFloat,
    @ViewBuilder loadedContent: @escaping (Loader.Payload) -> LoadedContent
  ) {
    self.asset = asset
    self.fallbackSymbolName = fallbackSymbolName
    self.cornerRadius = cornerRadius
    self.fallbackFontSize = fallbackFontSize
    self.loadedContent = loadedContent
  }

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        .fill(.appOnSecondaryContainer.opacity(0.06))

      switch phase {
      case .idle, .unavailable:
        Image(systemName: fallbackSymbolName)
          .font(.system(size: fallbackFontSize, weight: .semibold))
          .foregroundStyle(.appOnSecondaryContainer.opacity(0.46))
      case .loading:
        ProgressView()
          .controlSize(.small)
          .tint(palette.onSecondaryContainer.opacity(0.52))
      case .loaded(let payload):
        loadedContent(payload)
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        .strokeBorder(.appOnSecondaryContainer.opacity(0.08), lineWidth: 1)
    }
    .task(id: SavedEntryMediaTaskID(asset: asset, reloadRevision: reloadRevision)) {
      await loadMedia()
    }
    .onReceive(NotificationCenter.default.publisher(
      for: JournalMediaFileChange.notificationName
    ).receive(on: RunLoop.main)) { notification in
      guard shouldReloadMedia(for: notification) else { return }
      reloadRevision += 1
    }
  }

  private func loadMedia() async {
    guard let asset else {
      phase = .unavailable
      return
    }

    phase = .loading
    let payload = await asset.load()

    guard Task.isCancelled == false else { return }

    guard let payload else {
      phase = .unavailable
      return
    }

    phase = .loaded(payload)
  }

  private func shouldReloadMedia(for notification: Notification) -> Bool {
    guard let asset else { return false }
    guard let changedAttachmentID = JournalMediaFileChange.attachmentID(from: notification) else {
      return true
    }
    return changedAttachmentID == asset.id
  }
}

/// Loaded photo content rendered with the requested scale mode.
private struct SavedEntryLoadedPhotoView: View {

  let image: UIImage
  let contentMode: ContentMode
  let imagePadding: CGFloat

  var body: some View {
    let image = Image(uiImage: image)

    switch contentMode {
    case .fill:
      image
        .resizable()
        .scaledToFill()
        .padding(imagePadding)
    case .fit:
      image
        .resizable()
        .scaledToFit()
        .padding(imagePadding)
    }
  }
}

/// Detail layout inside `SavedEntryCard`.
///
/// Detail does not inherit the grid summary's tilt or truncation, but it still
/// renders inside the same adaptive card wrapper and paper aspect ratio.
private struct SavedEntryDetailCardLayout: View {

  let display: SavedEntryDetailDisplay

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      SavedEntryDetailHeader(kind: display.kind, createdAt: display.createdAt)

      SavedEntryDetailContent(content: display.content)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

      SavedEntryDetailMetadata(
        createdAt: display.createdAt,
        updatedAt: display.updatedAt,
        location: display.location
      )
    }
  }
}

/// Kind and creation timestamp shown at the top of a detail card.
private struct SavedEntryDetailHeader: View {

  let kind: Card.Kind
  let createdAt: Date

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Label {
        Text(kind.savedEntryTitle)
      } icon: {
        Image(systemName: kind.symbolName)
      }
      .font(.headline.weight(.semibold))
      .labelStyle(.titleAndIcon)

      Spacer(minLength: 0)

      Text(createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.appOnSecondaryContainer.opacity(0.56))
        .lineLimit(1)
    }
  }
}

/// Modality-specific detail content.
private struct SavedEntryDetailContent: View {

  let content: SavedEntryCardContent

  var body: some View {
    switch content {
    case .text(let text):
      SavedEntryDetailTextContent(text: text)
    case .audio(let fileURL):
      SavedEntryDetailAudioContent(fileURL: fileURL)
    case .image(let asset):
      SavedEntryDetailPhotoContent(asset: asset)
    case .capturedImage(let image):
      SavedEntryDetailCapturedPhotoContent(image: image)
    case .doodle(let asset):
      SavedEntryDetailDoodleContent(asset: asset)
    case .capturedDoodle(let drawing):
      SavedEntryDetailCapturedDoodleContent(drawing: drawing)
    case .bauhaus(let asset):
      SavedEntryDetailBauhausContent(asset: asset)
    case .capturedBauhaus(let document):
      SavedEntryDetailCapturedBauhausContent(document: document)
    case .unknown:
      SavedEntryUnknownContent()
    }
  }
}

/// Full text body for a saved text entry.
private struct SavedEntryDetailTextContent: View {

  let text: String

  var body: some View {
    ScrollView {
      Group {
        if text.isEmpty {
          Text("Untitled")
        } else {
          Text(text)
        }
      }
      .font(.title3.weight(.semibold))
      .lineSpacing(4)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .scrollIndicators(.hidden)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}

/// Large image well used by photo detail cards.
private struct SavedEntryDetailPhotoContent: View {

  let asset: SavedEntryMediaAsset<SavedEntryPhotoMediaLoader>?

  var body: some View {
    SavedEntryMediaContentView(
      asset: asset,
      fallbackSymbolName: "photo",
      cornerRadius: detailImageCornerRadius,
      fallbackFontSize: 58
    ) { image in
      SavedEntryLoadedPhotoView(
        image: image,
        contentMode: .fit,
        imagePadding: 0
      )
    }
    .aspectRatio(4 / 3, contentMode: .fit)
  }
}

/// Large read-only photo rendering for an unsaved draft payload.
private struct SavedEntryDetailCapturedPhotoContent: View {

  let image: UIImage?

  var body: some View {
    SavedEntryInlineMediaContentView(
      payload: image,
      fallbackSymbolName: "photo",
      cornerRadius: detailImageCornerRadius,
      fallbackFontSize: 58
    ) { image in
      SavedEntryLoadedPhotoView(
        image: image,
        contentMode: .fit,
        imagePadding: 0
      )
    }
    .aspectRatio(4 / 3, contentMode: .fit)
  }
}

/// Large read-only doodle rendering for a detail card.
private struct SavedEntryDetailDoodleContent: View {

  @Environment(\.appPalette) private var palette

  let asset: SavedEntryMediaAsset<SavedEntryDoodleMediaLoader>?

  var body: some View {
    SavedEntryMediaContentView(
      asset: asset,
      fallbackSymbolName: "scribble.variable",
      cornerRadius: detailImageCornerRadius,
      fallbackFontSize: 58
    ) { drawing in
      SavedEntryDoodleReplayContent(
        drawing: drawing,
        inkColor: palette.tint
      )
    }
    .aspectRatio(CardMetrics.aspectRatio, contentMode: .fit)
  }
}

/// Large read-only doodle rendering for an unsaved draft payload.
private struct SavedEntryDetailCapturedDoodleContent: View {

  @Environment(\.appPalette) private var palette

  let drawing: DoodleDrawing?

  var body: some View {
    SavedEntryInlineMediaContentView(
      payload: drawing,
      fallbackSymbolName: "scribble.variable",
      cornerRadius: detailImageCornerRadius,
      fallbackFontSize: 58
    ) { drawing in
      SavedEntryDoodleReplayContent(
        drawing: drawing,
        inkColor: palette.tint
      )
    }
    .aspectRatio(CardMetrics.aspectRatio, contentMode: .fit)
  }
}

/// Detail doodle content with read-only stroke replay controls.
private struct SavedEntryDoodleReplayContent: View {

  let drawing: DoodleDrawing
  let inkColor: Color

  @State private var isPlaying = false

  var body: some View {
    ZStack(alignment: .bottomLeading) {
      DoodleDrawingReplayView(
        drawing: drawing,
        inkColor: inkColor,
        displayAspectRatio: CardMetrics.aspectRatio,
        isPlaying: $isPlaying
      )
      .padding(20)

      Button {
        isPlaying.toggle()
      } label: {
        if isPlaying {
          Label("Stop", systemImage: "stop.fill")
        } else {
          Label("Replay", systemImage: "play.fill")
        }
      }
      .font(.caption.weight(.semibold))
      .controlSize(.small)
      .buttonStyle(.bordered)
      .disabled(drawing.isEmpty)
      .padding(12)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onDisappear {
      isPlaying = false
    }
  }
}

/// Large read-only Bauhaus rendering for a detail card.
private struct SavedEntryDetailBauhausContent: View {

  let asset: SavedEntryMediaAsset<SavedEntryBauhausMediaLoader>?

  var body: some View {
    SavedEntryMediaContentView(
      asset: asset,
      fallbackSymbolName: "square.grid.3x3.square",
      cornerRadius: detailImageCornerRadius,
      fallbackFontSize: 58
    ) { document in
      SavedEntryBauhausReplayContent(document: document)
    }
    .aspectRatio(4 / 3, contentMode: .fit)
  }
}

/// Large read-only Bauhaus rendering for an unsaved draft payload.
private struct SavedEntryDetailCapturedBauhausContent: View {

  let document: BauhausGridDocument?

  var body: some View {
    SavedEntryInlineMediaContentView(
      payload: document,
      fallbackSymbolName: "square.grid.3x3.square",
      cornerRadius: detailImageCornerRadius,
      fallbackFontSize: 58
    ) { document in
      SavedEntryBauhausReplayContent(document: document)
    }
    .aspectRatio(4 / 3, contentMode: .fit)
  }
}

/// Detail Bauhaus content with read-only replay controls when history exists.
private struct SavedEntryBauhausReplayContent: View {

  let document: BauhausGridDocument

  @State private var isPlaying = false

  var body: some View {
    ZStack(alignment: .bottomLeading) {
      BauhausGridReplayView(document: document, isPlaying: $isPlaying)
        .padding(12)

      if document.replay?.isEmpty == false {
        Button {
          isPlaying.toggle()
        } label: {
          if isPlaying {
            Label("Stop", systemImage: "stop.fill")
          } else {
            Label("Replay", systemImage: "play.fill")
          }
        }
        .font(.caption.weight(.semibold))
        .controlSize(.small)
        .buttonStyle(.bordered)
        .padding(12)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onDisappear {
      isPlaying = false
    }
  }
}

/// Playback affordance for an audio entry when its local media file is available.
private struct SavedEntryDetailAudioContent: View {

  let fileURL: URL?

  @State private var playback = SavedEntryAudioPlayback()

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      ZStack {
        Circle()
          .fill(.appOnSecondaryContainer.opacity(0.08))
          .frame(width: 68, height: 68)

        Image(systemName: "waveform")
          .font(.system(size: 34, weight: .semibold))
          .foregroundStyle(.appOnSecondaryContainer.opacity(0.78))
      }

      SavedEntryAudioWaveform(
        barWidth: 7,
        minimumHeight: 18,
        maximumAddedHeight: 82,
        opacity: fileURL == nil ? 0.18 : 0.42
      )
      .frame(height: 120)

      HStack(spacing: 12) {
        Button {
          guard let fileURL else { return }
          playback.toggle(fileURL: fileURL)
        } label: {
          if playback.isPlaying {
            Label("Pause", systemImage: "pause.fill")
          } else {
            Label("Play", systemImage: "play.fill")
          }
        }
        .buttonStyle(.bordered)
        .disabled(fileURL == nil)

        Group {
          if fileURL == nil {
            Text("Audio file unavailable")
          } else {
            Text("Audio recording")
          }
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.appOnSecondaryContainer.opacity(0.58))
      }

      if let errorMessage = playback.errorMessage {
        Text(errorMessage)
          .font(.footnote)
          .foregroundStyle(.red)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .onReceive(Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()) { _ in
      playback.refreshPlaybackState()
    }
    .onDisappear {
      playback.stop()
    }
  }
}

/// Main-actor audio player state for persisted audio entries.
///
/// The model is view-local because playback is a transient presentation concern:
/// no SwiftData fields change when the user plays or pauses a recording.
@MainActor
@Observable
private final class SavedEntryAudioPlayback {

  var isPlaying = false
  var errorMessage: LocalizedStringResource?

  @ObservationIgnored private var player: AVAudioPlayer?
  @ObservationIgnored private var sourceURL: URL?

  func toggle(fileURL: URL) {
    if player?.isPlaying == true {
      player?.pause()
      isPlaying = false
      return
    }

    do {
      if sourceURL != fileURL || player == nil {
        let nextPlayer = try AVAudioPlayer(contentsOf: fileURL)
        nextPlayer.prepareToPlay()
        player = nextPlayer
        sourceURL = fileURL
      }

      if let player, player.currentTime >= player.duration {
        player.currentTime = 0
      }

      player?.play()
      isPlaying = player?.isPlaying == true
      errorMessage = nil
    } catch {
      player = nil
      sourceURL = nil
      isPlaying = false
      errorMessage = "Could not play this recording."
    }
  }

  func refreshPlaybackState() {
    guard let player else {
      isPlaying = false
      return
    }

    if isPlaying && player.isPlaying == false {
      if player.currentTime >= player.duration {
        player.currentTime = 0
      }
      isPlaying = false
    }
  }

  func stop() {
    player?.stop()
    player = nil
    sourceURL = nil
    isPlaying = false
  }
}

/// Timestamp and optional metadata rows for a detail card.
private struct SavedEntryDetailMetadata: View {

  let createdAt: Date
  let updatedAt: Date
  let location: Coordinate?

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      SavedEntryDetailDateMetadataRow(
        symbolName: "calendar",
        title: "Created",
        date: createdAt
      )

      if updatedAt.timeIntervalSince(createdAt) > 1 {
        SavedEntryDetailDateMetadataRow(
          symbolName: "clock.arrow.circlepath",
          title: "Updated",
          date: updatedAt
        )
      }

      if location != nil {
        SavedEntryDetailTextMetadataRow(
          symbolName: "location.fill",
          title: "Location",
          value: "Attached"
        )
      }
    }
    .padding(.top, 4)
  }
}

/// Date-valued metadata row.
private struct SavedEntryDetailDateMetadataRow: View {

  let symbolName: String
  let title: LocalizedStringResource
  let date: Date

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: symbolName)
        .frame(width: 18)

      Text(title)

      Spacer(minLength: 0)

      Text(date, format: .dateTime.year().month().day().hour().minute())
    }
    .font(.caption.weight(.medium))
    .foregroundStyle(.appOnSecondaryContainer.opacity(0.56))
  }
}

/// Text-valued metadata row.
private struct SavedEntryDetailTextMetadataRow: View {

  let symbolName: String
  let title: LocalizedStringResource
  let value: LocalizedStringResource

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: symbolName)
        .frame(width: 18)

      Text(title)

      Spacer(minLength: 0)

      Text(value)
    }
    .font(.caption.weight(.medium))
    .foregroundStyle(.appOnSecondaryContainer.opacity(0.56))
  }
}

/// Short-lived values a pure grid summary card needs.
///
/// `SavedEntrySummaryCardHost` derives this from a live SwiftData `Card` inside
/// its body. Keeping that host separate lets this value component stay
/// previewable without turning saved entries into stale long-lived snapshots.
private struct SavedEntrySummaryDisplay: Identifiable {
  let id: UUID

  /// Exactly one visual/content modality for the summary card.
  let content: SavedEntryCardContent

  /// Creation date rendered in the summary footer.
  let createdAt: Date

  /// Stable visual tilt for the grid summary only.
  let tilt: Angle
}

/// The values a pushed detail card needs.
private struct SavedEntryDetailDisplay: Identifiable {
  let id: UUID

  /// Persisted modality that chooses the detail header and content layout.
  let kind: Card.Kind

  /// Exactly one visual/content modality for the detail card.
  let content: SavedEntryCardContent

  let createdAt: Date
  let updatedAt: Date
  let location: Coordinate?
}

/// Typed reference to a persisted media attachment.
///
/// This is intentionally not a SwiftData `Attachment` and not a ready-made
/// `Image`: saved-entry views can stay previewable/value-driven, while the
/// display payload is loaded from the local asset file only when needed. The
/// `Loader` names both the value shape the asset will produce and the decoding
/// policy that turns attachment bytes into that value.
private struct SavedEntryMediaAsset<Loader: SavedEntryMediaLoading>: Sendable {
  let id: UUID
  let fileURL: URL?

  func load() async -> Loader.Payload? {
    guard let fileURL else { return nil }
    return await Loader.load(from: fileURL)
  }
}

/// Loading phase for a saved media preview.
private enum SavedEntryMediaLoadPhase<Payload: Sendable> {
  case idle
  case loading
  case loaded(Payload)
  case unavailable
}

/// Stable identity for a media loading task.
private struct SavedEntryMediaTaskID: Equatable {
  let assetID: UUID?
  let filePath: String?
  let reloadRevision: Int

  init<Loader: SavedEntryMediaLoading>(
    asset: SavedEntryMediaAsset<Loader>?,
    reloadRevision: Int
  ) {
    self.assetID = asset?.id
    self.filePath = asset?.fileURL?.path
    self.reloadRevision = reloadRevision
  }
}

/// Loader contract for one persisted media payload shape.
private protocol SavedEntryMediaLoading: Sendable {
  associatedtype Payload: Sendable

  /// Decodes the persisted media file into the payload this loader owns.
  @MainActor
  static func load(from fileURL: URL) async -> Payload?
}

/// Loads a still-photo attachment file into a display image.
private enum SavedEntryPhotoMediaLoader: SavedEntryMediaLoading {
  static func load(from fileURL: URL) async -> UIImage? {
    guard
      let data = await SavedEntryMediaFileReader.data(from: fileURL),
      let image = UIImage(data: data)
    else {
      return nil
    }
    return image
  }
}

/// Loads a doodle attachment file into editable vector drawing data.
private enum SavedEntryDoodleMediaLoader: SavedEntryMediaLoading {
  static func load(from fileURL: URL) async -> DoodleDrawing? {
    guard let data = await SavedEntryMediaFileReader.data(from: fileURL) else { return nil }
    return try? JSONDecoder().decode(DoodleDrawing.self, from: data)
  }
}

/// Loads a Bauhaus attachment file into editable grid document data.
private enum SavedEntryBauhausMediaLoader: SavedEntryMediaLoading {
  static func load(from fileURL: URL) async -> BauhausGridDocument? {
    guard let data = await SavedEntryMediaFileReader.data(from: fileURL) else { return nil }
    return try? JSONDecoder().decode(BauhausGridDocument.self, from: data)
  }
}

/// File I/O shared by the typed media loaders.
private enum SavedEntryMediaFileReader {
  nonisolated static func data(from fileURL: URL) async -> Data? {
    await Task.detached(priority: .utility) {
      try? Data(contentsOf: fileURL)
    }.value
  }
}

/// Errors surfaced when a saved entry cannot be reopened as an editable draft.
private enum SavedEntryEditDraftError: LocalizedError {
  case mediaUnavailable
  case mediaDecodeFailed
  case audioCopyFailed
  case unsupportedKind

  var errorDescription: String? {
    switch self {
    case .mediaUnavailable:
      return "This entry's media file is not available on this device yet."
    case .mediaDecodeFailed:
      return "This entry's media file could not be read for editing."
    case .audioCopyFailed:
      return "This audio recording could not be prepared for editing."
    case .unsupportedKind:
      return "This entry type is not editable yet."
    }
  }
}

/// File preparation needed before persisted media can re-enter the edit pipeline.
private enum SavedEntryEditMediaPreparer {

  @MainActor
  static func audioCopy(from sourceURL: URL) throws -> URL {
    guard FileManager.default.fileExists(atPath: sourceURL.path) else {
      throw SavedEntryEditDraftError.mediaUnavailable
    }

    let pathExtension = sourceURL.pathExtension.isEmpty ? "m4a" : sourceURL.pathExtension
    let destinationURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("journal-edit-audio-\(UUID().uuidString)")
      .appendingPathExtension(pathExtension)

    do {
      try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
      return destinationURL
    } catch {
      throw SavedEntryEditDraftError.audioCopyFailed
    }
  }

  @MainActor
  static func audioDuration(from fileURL: URL) -> TimeInterval {
    (try? AVAudioPlayer(contentsOf: fileURL).duration) ?? 0
  }
}

extension UIImage {

  /// Pixel dimensions for persistence metadata derived from reloaded image data.
  fileprivate var pixelSize: CGSize {
    CGSize(width: size.width * scale, height: size.height * scale)
  }
}

/// The mutually-exclusive content variants shown by saved-entry cards.
private enum SavedEntryCardContent {
  /// A text capture; media captures never use this as a caption.
  case text(String)

  /// An audio capture, with the local media URL when the file is available.
  case audio(fileURL: URL?)

  /// A still image capture, decoded from its persisted asset file by `SavedEntryPhotoMediaLoader`.
  case image(SavedEntryMediaAsset<SavedEntryPhotoMediaLoader>?)

  /// A still image capture that exists only in an unsaved draft.
  case capturedImage(UIImage?)

  /// A doodle capture, decoded from its persisted asset file by `SavedEntryDoodleMediaLoader`.
  case doodle(SavedEntryMediaAsset<SavedEntryDoodleMediaLoader>?)

  /// A doodle capture that exists only in an unsaved draft.
  case capturedDoodle(DoodleDrawing?)

  /// A Bauhaus capture, decoded from its persisted asset file by `SavedEntryBauhausMediaLoader`.
  case bauhaus(SavedEntryMediaAsset<SavedEntryBauhausMediaLoader>?)

  /// A Bauhaus capture that exists only in an unsaved draft.
  case capturedBauhaus(BauhausGridDocument?)

  /// A card whose modality this build does not recognize. Carries no payload — it
  /// renders as a neutral placeholder.
  case unknown

  var kind: Card.Kind {
    switch self {
    case .text: .text
    case .audio: .audio
    case .image, .capturedImage: .photo
    case .doodle, .capturedDoodle: .doodle
    case .bauhaus, .capturedBauhaus: .bauhaus
    case .unknown: .unknown
    }
  }
}

// MARK: - Formatting Helpers

extension CardEditDraft {

  /// Entry-card display values for an unsaved draft.
  fileprivate var summaryDisplay: SavedEntrySummaryDisplay {
    SavedEntrySummaryDisplay(
      id: displayID,
      content: entryCardContent,
      createdAt: createdAt,
      tilt: displayID.tiltAngle
    )
  }

  private var entryCardContent: SavedEntryCardContent {
    switch kind {
    case .text:
      return .text(text.trimmingCharacters(in: .whitespacesAndNewlines))
    case .photo:
      return .capturedImage(photo?.image)
    case .audio:
      return .audio(fileURL: audio?.fileURL)
    case .doodle:
      return .capturedDoodle(doodle)
    case .bauhaus:
      return .capturedBauhaus(bauhaus)
    case .unknown:
      return .unknown
    @unknown default:
      return .unknown
    }
  }
}

extension Card {

  /// Rehydrates this saved card into the shared editing draft model.
  ///
  /// The method intentionally starts from the live SwiftData card, then reads
  /// local attachment files only at presentation time. A missing media file
  /// therefore blocks editing instead of producing a lossy replacement draft.
  @MainActor
  fileprivate func editDraft() async throws -> CardEditDraft {
    let attachments = (attachments ?? []).sorted { $0.createdAt < $1.createdAt }

    switch kind {
    case .text:
      return CardEditDraft(
        kind: .text,
        text: body,
        location: location
      )
    case .photo:
      guard
        let fileURL = attachments.first(matching: .photo)?.mediaFileURL,
        let data = await SavedEntryMediaFileReader.data(from: fileURL)
      else {
        throw SavedEntryEditDraftError.mediaUnavailable
      }
      guard let image = UIImage(data: data) else {
        throw SavedEntryEditDraftError.mediaDecodeFailed
      }
      return CardEditDraft(
        kind: .photo,
        text: body,
        photo: CapturedPhoto(imageData: data, pixelSize: image.pixelSize),
        location: location
      )
    case .audio:
      guard let fileURL = attachments.first(matching: .audio)?.mediaFileURL else {
        throw SavedEntryEditDraftError.mediaUnavailable
      }
      let editableURL = try SavedEntryEditMediaPreparer.audioCopy(from: fileURL)
      return CardEditDraft(
        kind: .audio,
        text: body,
        audio: AudioRecording(
          fileURL: editableURL,
          duration: SavedEntryEditMediaPreparer.audioDuration(from: editableURL)
        ),
        location: location
      )
    case .doodle:
      guard
        let fileURL = attachments.first(matching: .doodle)?.mediaFileURL,
        let data = await SavedEntryMediaFileReader.data(from: fileURL)
      else {
        throw SavedEntryEditDraftError.mediaUnavailable
      }
      guard let drawing = try? JSONDecoder().decode(DoodleDrawing.self, from: data) else {
        throw SavedEntryEditDraftError.mediaDecodeFailed
      }
      return CardEditDraft(
        kind: .doodle,
        text: body,
        doodle: drawing,
        location: location
      )
    case .bauhaus:
      guard
        let fileURL = attachments.first(matching: .bauhaus)?.mediaFileURL,
        let data = await SavedEntryMediaFileReader.data(from: fileURL)
      else {
        throw SavedEntryEditDraftError.mediaUnavailable
      }
      guard let document = try? JSONDecoder().decode(BauhausGridDocument.self, from: data) else {
        throw SavedEntryEditDraftError.mediaDecodeFailed
      }
      return CardEditDraft(
        kind: .bauhaus,
        text: body,
        bauhaus: document,
        location: location
      )
    case .unknown:
      throw SavedEntryEditDraftError.unsupportedKind
    @unknown default:
      throw SavedEntryEditDraftError.unsupportedKind
    }
  }

  fileprivate var summaryDisplay: SavedEntrySummaryDisplay {
    let attachments = (attachments ?? []).sorted { $0.createdAt < $1.createdAt }
    let content: SavedEntryCardContent = {
      switch kind {
      case .text:
        return .text(body.trimmingCharacters(in: .whitespacesAndNewlines))
      case .photo:
        return .image(attachments.first(matching: .photo)?.photoAsset)
      case .audio:
        return .audio(fileURL: nil)
      case .doodle:
        return .doodle(attachments.first(matching: .doodle)?.doodleAsset)
      case .bauhaus:
        return .bauhaus(attachments.first(matching: .bauhaus)?.bauhausAsset)
      case .unknown:
        return .unknown
      @unknown default:
        return .unknown
      }
    }()

    return SavedEntrySummaryDisplay(
      id: id,
      content: content,
      createdAt: createdAt,
      tilt: tiltAngle
    )
  }

  fileprivate var detailDisplay: SavedEntryDetailDisplay {
    let attachments = (attachments ?? []).sorted { $0.createdAt < $1.createdAt }
    let content: SavedEntryCardContent = {
      switch kind {
      case .text:
        return .text(body.trimmingCharacters(in: .whitespacesAndNewlines))
      case .photo:
        return .image(attachments.first(matching: .photo)?.photoAsset)
      case .audio:
        return .audio(fileURL: attachments.first(matching: .audio)?.mediaFileURL)
      case .doodle:
        return .doodle(attachments.first(matching: .doodle)?.doodleAsset)
      case .bauhaus:
        return .bauhaus(attachments.first(matching: .bauhaus)?.bauhausAsset)
      case .unknown:
        return .unknown
      @unknown default:
        return .unknown
      }
    }()

    return SavedEntryDetailDisplay(
      id: id,
      kind: kind,
      content: content,
      createdAt: createdAt,
      updatedAt: updatedAt,
      location: location
    )
  }

  /// A small, stable tilt derived from the card's id. Deriving it from the id
  /// (rather than `Double.random` inside `body`) keeps each card at a fixed
  /// angle across launches and stops it from re-rolling every time the body is
  /// re-evaluated.
  fileprivate var tiltAngle: Angle {
    id.tiltAngle
  }
}

extension UUID {

  /// A small, stable tilt derived from a card-like id.
  fileprivate var tiltAngle: Angle {
    let bytes = uuid
    let seed = UInt(bytes.0) &+ (UInt(bytes.7) &* 31) &+ (UInt(bytes.15) &* 131)
    let fraction = Double(seed % 1000) / 999  // 0...1
    return .degrees((fraction * 2 - 1) * cardMaxTilt)  // -max ... +max
  }
}

extension Card.Kind {

  /// User-facing name for entries list and detail presentation.
  fileprivate var savedEntryTitle: LocalizedStringResource {
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
    case .unknown:
      return "Unknown"
    @unknown default:
      return "Unknown"
    }
  }

  /// SF Symbol shown in the footer for this card pattern.
  fileprivate var symbolName: String {
    switch self {
    case .text: "text.alignleft"
    case .photo: "photo"
    case .audio: "waveform"
    case .doodle: "scribble.variable"
    case .bauhaus: "square.grid.3x3.square"
    case .unknown: "questionmark"
    @unknown default: "questionmark"
    }
  }
}

extension Array where Element == Attachment {

  fileprivate func first(matching kind: Attachment.Kind) -> Attachment? {
    first { $0.kind == kind }
  }
}

extension Attachment {

  fileprivate var photoAsset: SavedEntryMediaAsset<SavedEntryPhotoMediaLoader> {
    SavedEntryMediaAsset(
      id: id,
      fileURL: mediaFileURL
    )
  }

  fileprivate var doodleAsset: SavedEntryMediaAsset<SavedEntryDoodleMediaLoader> {
    SavedEntryMediaAsset(
      id: id,
      fileURL: mediaFileURL
    )
  }

  fileprivate var bauhausAsset: SavedEntryMediaAsset<SavedEntryBauhausMediaLoader> {
    SavedEntryMediaAsset(
      id: id,
      fileURL: mediaFileURL
    )
  }

  fileprivate var mediaFileURL: URL? {
    try? JournalStore.fileURL(for: self)
  }
}

// MARK: - Previews

/// Xcode Preview harness for the saved-entry card patterns.
///
/// The production list keeps a live SwiftData `Card` at the observation boundary,
/// while the card itself consumes these short-lived display values. Exercising
/// that value path here keeps the Preview independent of CloudKit, SwiftData, and
/// app-group media files.
private struct SavedEntryCardPatternsPreview: View {

  var body: some View {
    PrimaryContainer(theme: .default) {
      ScrollView {
        VStack(alignment: .leading, spacing: 28) {
          SavedEntrySummaryCardPatternsPreview()
          SavedEntryDetailCardPatternsPreview()
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .background(.appPrimaryContainer)
    }
  }
}

/// Grid-sized preview of every saved-entry summary card pattern.
private struct SavedEntrySummaryCardPatternsPreview: View {

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Summary")
        .font(.headline)

      LazyVGrid(columns: columns, spacing: 16) {
        ForEach(SavedEntryCardPreviewData.summaryDisplays) { display in
          SavedEntryCard(presentation: .summary(display))
        }
      }
    }
  }

  private var columns: [GridItem] {
    [
      GridItem(.adaptive(minimum: 148, maximum: 180), spacing: 16)
    ]
  }
}

/// Detail-sized preview of every saved-entry card pattern.
private struct SavedEntryDetailCardPatternsPreview: View {

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Detail")
        .font(.headline)

      ScrollView(.horizontal) {
        HStack(alignment: .top, spacing: 16) {
          ForEach(SavedEntryCardPreviewData.detailDisplays) { display in
            SavedEntryCard(presentation: .detail(display))
              .frame(width: 340)
          }
        }
        .padding(.vertical, 4)
      }
      .scrollIndicators(.hidden)
    }
  }
}

/// Stable sample values for the saved-entry card Xcode Preview.
private enum SavedEntryCardPreviewData {

  static var summaryDisplays: [SavedEntrySummaryDisplay] {
    [
      .init(
        id: previewID(1),
        content: .text(shortText),
        createdAt: referenceDate.addingTimeInterval(-18 * 60),
        tilt: .degrees(-1.8)
      ),
      .init(
        id: previewID(2),
        content: .image(nil),
        createdAt: referenceDate.addingTimeInterval(-52 * 60),
        tilt: .degrees(1.2)
      ),
      .init(
        id: previewID(3),
        content: .audio(fileURL: nil),
        createdAt: referenceDate.addingTimeInterval(-2 * 60 * 60),
        tilt: .degrees(-0.6)
      ),
      .init(
        id: previewID(4),
        content: .doodle(nil),
        createdAt: referenceDate.addingTimeInterval(-5 * 60 * 60),
        tilt: .degrees(2.1)
      ),
      .init(
        id: previewID(5),
        content: .bauhaus(nil),
        createdAt: referenceDate.addingTimeInterval(-8 * 60 * 60),
        tilt: .degrees(-2.4)
      ),
      .init(
        id: previewID(6),
        content: .unknown,
        createdAt: referenceDate.addingTimeInterval(-11 * 60 * 60),
        tilt: .degrees(0.9)
      ),
    ]
  }

  static var detailDisplays: [SavedEntryDetailDisplay] {
    [
      .init(
        id: previewID(11),
        kind: .text,
        content: .text(longText),
        createdAt: referenceDate.addingTimeInterval(-40 * 60),
        updatedAt: referenceDate.addingTimeInterval(-12 * 60),
        location: Coordinate(latitude: 35.6812, longitude: 139.7671)
      ),
      .init(
        id: previewID(12),
        kind: .photo,
        content: .image(nil),
        createdAt: referenceDate.addingTimeInterval(-3 * 60 * 60),
        updatedAt: referenceDate.addingTimeInterval(-3 * 60 * 60),
        location: nil
      ),
      .init(
        id: previewID(13),
        kind: .audio,
        content: .audio(fileURL: nil),
        createdAt: referenceDate.addingTimeInterval(-6 * 60 * 60),
        updatedAt: referenceDate.addingTimeInterval(-6 * 60 * 60),
        location: nil
      ),
      .init(
        id: previewID(14),
        kind: .doodle,
        content: .doodle(nil),
        createdAt: referenceDate.addingTimeInterval(-24 * 60 * 60),
        updatedAt: referenceDate.addingTimeInterval(-24 * 60 * 60),
        location: Coordinate(latitude: 34.6937, longitude: 135.5023)
      ),
      .init(
        id: previewID(15),
        kind: .bauhaus,
        content: .bauhaus(nil),
        createdAt: referenceDate.addingTimeInterval(-2 * 24 * 60 * 60),
        updatedAt: referenceDate.addingTimeInterval(-2 * 24 * 60 * 60),
        location: nil
      ),
      .init(
        id: previewID(16),
        kind: .unknown,
        content: .unknown,
        createdAt: referenceDate.addingTimeInterval(-3 * 24 * 60 * 60),
        updatedAt: referenceDate.addingTimeInterval(-3 * 24 * 60 * 60),
        location: nil
      ),
    ]
  }

  private static var referenceDate: Date {
    Date(timeIntervalSinceReferenceDate: 805_248_000)
  }

  private static var shortText: String {
    "The long way home had better light than the shortcut."
  }

  private static var longText: String {
    """
    Walked out before the city was fully awake and found the river already bright.
    The useful part was not the route, but the ten quiet minutes before checking anything.
    """
  }

  private static func previewID(_ value: UInt8) -> UUID {
    UUID(uuid: (
      0x53, 0x61, 0x76, 0x65,
      0x64, 0x45,
      0x6e, 0x74,
      0x72, 0x79,
      0x00, value,
      0x00, 0x00, 0x00, value
    ))
  }
}

#Preview("Card Patterns") {
  SavedEntryCardPatternsPreview()
}
