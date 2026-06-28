import AVFoundation
import CaptureBauhaus
import CaptureDoodle
import Combine
import JournalModel
import MuColor
import Observation
import SwiftUI
import UIKit

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

  let card: Card
  let onShare: @MainActor (Card) -> Void

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
      ToolbarItem(placement: .topBarTrailing) {
        Button {
          onShare(card)
        } label: {
          Image(systemName: "square.and.arrow.up")
        }
        .accessibilityLabel("Share")
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
      case .doodle(let asset):
        SavedEntrySummaryDoodleContent(asset: asset)
      case .bauhaus(let asset):
        SavedEntrySummaryBauhausContent(asset: asset)
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

/// Bauhaus cards render the decoded grid as live SwiftUI content.
private struct SavedEntrySummaryBauhausContent: View {

  let asset: SavedEntryMediaAsset<SavedEntryBauhausMediaLoader>?

  var body: some View {
    SavedEntryMediaContentView(
      asset: asset,
      fallbackSymbolName: "square.grid.3x3.square",
      cornerRadius: 10,
      fallbackFontSize: 34
    ) { artwork in
      BauhausGridArtworkView(artwork: artwork)
        .padding(12)
    }
    .aspectRatio(4 / 3, contentMode: .fit)
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

      if display.title.isEmpty == false {
        SavedEntryDetailTitle(text: display.title)
      }

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

/// Optional explicit title stored on a card.
private struct SavedEntryDetailTitle: View {

  let text: String

  var body: some View {
    Text(text)
      .font(.title2.weight(.semibold))
      .frame(maxWidth: .infinity, alignment: .leading)
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
    case .doodle(let asset):
      SavedEntryDetailDoodleContent(asset: asset)
    case .bauhaus(let asset):
      SavedEntryDetailBauhausContent(asset: asset)
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
    ) { artwork in
      BauhausGridArtworkView(artwork: artwork)
        .padding(12)
    }
    .aspectRatio(4 / 3, contentMode: .fit)
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

  /// Optional user-authored title, already trimmed for display.
  let title: String

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

/// Loads a Bauhaus attachment file into editable grid artwork data.
private enum SavedEntryBauhausMediaLoader: SavedEntryMediaLoading {
  static func load(from fileURL: URL) async -> BauhausGridArtwork? {
    guard let data = await SavedEntryMediaFileReader.data(from: fileURL) else { return nil }
    return try? JSONDecoder().decode(BauhausGridArtwork.self, from: data)
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

/// The mutually-exclusive content variants shown by saved-entry cards.
private enum SavedEntryCardContent {
  /// A text capture; media captures never use this as a caption.
  case text(String)

  /// An audio capture, with the local media URL when the file is available.
  case audio(fileURL: URL?)

  /// A still image capture, decoded from its persisted asset file by `SavedEntryPhotoMediaLoader`.
  case image(SavedEntryMediaAsset<SavedEntryPhotoMediaLoader>?)

  /// A doodle capture, decoded from its persisted asset file by `SavedEntryDoodleMediaLoader`.
  case doodle(SavedEntryMediaAsset<SavedEntryDoodleMediaLoader>?)

  /// A Bauhaus capture, decoded from its persisted asset file by `SavedEntryBauhausMediaLoader`.
  case bauhaus(SavedEntryMediaAsset<SavedEntryBauhausMediaLoader>?)

  var kind: Card.Kind {
    switch self {
    case .text: .text
    case .audio: .audio
    case .image: .photo
    case .doodle: .doodle
    case .bauhaus: .bauhaus
    }
  }
}

// MARK: - Formatting Helpers

extension Card {
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
      @unknown default:
        return .text(body.trimmingCharacters(in: .whitespacesAndNewlines))
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
      @unknown default:
        return .text(body.trimmingCharacters(in: .whitespacesAndNewlines))
      }
    }()

    return SavedEntryDetailDisplay(
      id: id,
      kind: kind,
      title: title.trimmingCharacters(in: .whitespacesAndNewlines),
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
    let bytes = id.uuid
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
    @unknown default:
      return "Card"
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
