import AVFoundation
import Combine
import JournalModel
import MuColor
import Observation
import SwiftData
import SwiftUI
import UIKit

/// SwiftData + iCloud entries list.
///
/// Cards are grouped into local-calendar day sections, then laid out as a
/// responsive grid of portrait tiles shaped like a sheet of paper (1 : 1.4144,
/// via `CardSurface`). Compact widths keep the original two-column rhythm;
/// regular widths add columns as space allows. Each tile renders one captured
/// modality — text, audio, image, or doodle — because a captured thing becomes
/// its own Card rather than media-with-caption.
struct SavedListView: View {

  @Environment(\.calendar) private var calendar
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @Environment(\.appPalette) private var palette
  @Query(sort: \Card.createdAt, order: .reverse) private var cards: [Card]

  @State private var sharePreviewPresentation: CardSharePreviewPresentation?

  var body: some View {
    let columns = SavedListGrid.columns(for: horizontalSizeClass)
    // TODO: If Entries grows large enough for full-list grouping to show up in
    // profiling, move this boundary into persistence instead of adding a shallow
    // fetchLimit: store a day section key on `Card`, or fetch by month/year
    // ranges and group only the visible archive window.
    let daySections = SavedListDaySection.sections(for: cards, calendar: calendar)

    ScrollView {
      LazyVStack(alignment: .leading, spacing: daySectionSpacing) {
        ForEach(daySections) { section in
          SavedListDaySectionView(
            section: section,
            columns: columns,
            onShare: presentSharePreview
          )
        }
      }
      .padding(cardSpacing)
    }
    .overlay {
      if cards.isEmpty {
        ContentUnavailableView("No Cards", systemImage: "book.closed")
      }
    }
    .scrollContentBackground(.hidden)
    .background(.background)
    .navigationTitle("Entries")
    .navigationBarTitleDisplayMode(.inline)
    .sheet(item: $sharePreviewPresentation) { presentation in
      CardSharePreviewScreen(
        snapshot: presentation.snapshot,
        palette: presentation.palette
      )
    }
  }

  private func presentSharePreview(for card: Card) {
    sharePreviewPresentation = CardSharePreviewPresentation(
      snapshot: CardShareSnapshot(card: card),
      palette: palette
    )
  }
}

/// Presentation payload for the pre-share preview screen.
private struct CardSharePreviewPresentation: Identifiable {
  let id = UUID()
  let snapshot: CardShareSnapshot
  let palette: Palette
}

/// One local-calendar date bucket in the saved entries list.
///
/// Identity is the start-of-day `Date` in the active SwiftUI calendar
/// environment, so the section stays stable while cards are inserted, deleted,
/// or edited within the same day.
private struct SavedListDaySection: Identifiable {
  let id: Date
  let day: Date
  var cards: [Card]

  init(day: Date, cards: [Card]) {
    self.id = day
    self.day = day
    self.cards = cards
  }

  static func sections(for cards: [Card], calendar: Calendar) -> [SavedListDaySection] {
    var sectionIndexesByDay: [Date: Int] = [:]
    var sections: [SavedListDaySection] = []

    for card in cards {
      let day = calendar.startOfDay(for: card.createdAt)

      if let sectionIndex = sectionIndexesByDay[day] {
        sections[sectionIndex].cards.append(card)
      } else {
        sectionIndexesByDay[day] = sections.count
        sections.append(SavedListDaySection(day: day, cards: [card]))
      }
    }

    return sections
  }
}

/// Column strategy for the entries grid.
///
/// Compact widths intentionally preserve the original two-column composition.
/// Regular widths use an adaptive item so iPad gains more visible entries
/// without letting the paper tile become oversized.
private enum SavedListGrid {
  static func columns(for horizontalSizeClass: UserInterfaceSizeClass?) -> [GridItem] {
    if horizontalSizeClass == .compact {
      return compactColumns
    }

    return [
      GridItem(
        .adaptive(minimum: regularMinimumCardWidth, maximum: regularMaximumCardWidth),
        spacing: cardSpacing
      )
    ]
  }

  private static let compactColumns = [
    GridItem(.flexible(), spacing: cardSpacing),
    GridItem(.flexible(), spacing: cardSpacing),
  ]
}

/// Gutter between cards and around the grid, kept equal so columns and edges
/// share the same rhythm.
private let cardSpacing: CGFloat = 16

/// Vertical gap between date sections.
private let daySectionSpacing: CGFloat = 28

/// Gap between a date header and the cards for that day.
private let dayHeaderSpacing: CGFloat = 12

/// Smallest card width used by the iPad/regular-width grid.
private let regularMinimumCardWidth: CGFloat = 168

/// Largest card width used by the iPad/regular-width grid before adding another
/// column.
private let regularMaximumCardWidth: CGFloat = 220

/// Maximum absolute tilt for a card, in degrees. Each tile picks a stable angle
/// in `-cardMaxTilt ... +cardMaxTilt` from its id, giving the grid a loosely
/// hand-placed feel rather than a rigid one.
private let cardMaxTilt: Double = 3

/// Outer inset for the pushed entry detail screen.
private let detailScreenPadding: CGFloat = 16

/// Corner radius for large media wells inside the detail card.
private let detailImageCornerRadius: CGFloat = 14

// MARK: - Fileprivate Views

/// A single date section in the entries list.
private struct SavedListDaySectionView: View {

  let section: SavedListDaySection
  let columns: [GridItem]
  let onShare: @MainActor (Card) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: dayHeaderSpacing) {
      SavedListDayHeader(day: section.day)

      LazyVGrid(columns: columns, spacing: cardSpacing) {
        ForEach(section.cards) { card in
          NavigationLink {
            SavedEntryDetailView(
              card: card,
              onShare: onShare
            )
          } label: {
            SavedEntrySummaryCard(display: card.summaryDisplay)
          }
          .buttonStyle(.plain)
          .contextMenu {
            SavedEntrySummaryCardContextMenu(
              card: card,
              onShare: onShare
            )
          }
        }
      }
    }
  }
}

/// Localized date label for a saved-entry section.
private struct SavedListDayHeader: View {

  let day: Date

  var body: some View {
    Text(day, format: .dateTime.weekday(.abbreviated).month(.wide).day().year())
      .font(.headline)
      .foregroundStyle(.appOnPrimaryContainer.opacity(0.72))
      .accessibilityAddTraits(.isHeader)
  }
}

/// Detail screen for one saved entry.
///
/// The screen owns navigation chrome and actions; the actual card body is a
/// separate detail component so grid summaries can evolve independently.
private struct SavedEntryDetailView: View {

  let card: Card
  let onShare: @MainActor (Card) -> Void

  var body: some View {
    ScrollView {
      SavedEntryDetailCard(display: card.detailDisplay)
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

/// A saved entry as a compact grid summary.
///
/// This component intentionally keeps the dense-list behavior: fixed paper
/// aspect ratio, clipped media previews, short text, and a stable per-card tilt.
private struct SavedEntrySummaryCard: View {

  let display: SavedEntrySummaryDisplay

  var body: some View {
    CardSurface {
      VStack(alignment: .leading, spacing: 10) {
        SavedEntrySummaryCardContent(content: display.content)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

        SavedEntrySummaryCardFooter(createdAt: display.createdAt, kind: display.content.kind)
      }
    }
    .rotationEffect(display.tilt)
    .accessibilityElement(children: .combine)
  }
}

/// Context actions for one saved-entry summary card.
private struct SavedEntrySummaryCardContextMenu: View {

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
      case .image(let image):
        SavedEntrySummaryImageContent(image: image)
      case .doodle(let image):
        SavedEntrySummaryDoodleContent(image: image)
      case .bauhaus(let image):
        SavedEntrySummaryDoodleContent(
          image: image,
          fallbackSymbolName: "square.grid.3x3.square"
        )
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

/// Photo/image cards use their thumbnail as the whole visual body.
private struct SavedEntrySummaryImageContent: View {

  let image: Image?

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(.appOnSecondaryContainer.opacity(0.06))

      if let image {
        image
          .resizable()
          .scaledToFill()
      } else {
        Image(systemName: "photo")
          .font(.system(size: 34, weight: .semibold))
          .foregroundStyle(.appOnSecondaryContainer.opacity(0.46))
      }
    }
    .aspectRatio(4 / 3, contentMode: .fit)
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .strokeBorder(.appOnSecondaryContainer.opacity(0.08), lineWidth: 1)
    }
  }
}

/// Doodle cards preserve the drawing as an object on the paper, not as a captioned
/// note. A missing thumbnail falls back to the same modality icon used in the footer.
private struct SavedEntrySummaryDoodleContent: View {

  let image: Image?
  let fallbackSymbolName: String

  init(image: Image?, fallbackSymbolName: String = "scribble.variable") {
    self.image = image
    self.fallbackSymbolName = fallbackSymbolName
  }

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(.appOnSecondaryContainer.opacity(0.05))

      if let image {
        image
          .resizable()
          .scaledToFit()
          .padding(12)
      } else {
        Image(systemName: fallbackSymbolName)
          .font(.system(size: 34, weight: .semibold))
          .foregroundStyle(.appOnSecondaryContainer.opacity(0.46))
      }
    }
    .aspectRatio(4 / 3, contentMode: .fit)
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .strokeBorder(.appOnSecondaryContainer.opacity(0.08), lineWidth: 1)
    }
  }
}

/// A saved entry rendered for the pushed detail screen.
///
/// Unlike the grid summary, this card is not tilted or aspect-ratio constrained:
/// detail should show the entry's content rather than preserve a browsing tile.
private struct SavedEntryDetailCard: View {

  let display: SavedEntryDetailDisplay

  var body: some View {
    VStack(alignment: .leading, spacing: 22) {
      SavedEntryDetailHeader(kind: display.kind, createdAt: display.createdAt)

      if display.title.isEmpty == false {
        SavedEntryDetailTitle(text: display.title)
      }

      SavedEntryDetailContent(content: display.content)

      SavedEntryDetailMetadata(
        createdAt: display.createdAt,
        updatedAt: display.updatedAt,
        location: display.location
      )
    }
    .padding(24)
    .frame(maxWidth: .infinity, minHeight: 420, alignment: .topLeading)
    .foregroundStyle(.appOnSecondaryContainer)
    .background {
      RoundedRectangle(cornerRadius: CardMetrics.cornerRadius, style: .continuous)
        .fill(.appSecondaryContainer)
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
    case .image(let image):
      SavedEntryDetailImageContent(
        image: image,
        fallbackSymbolName: "photo",
        imagePadding: 0
      )
    case .doodle(let image):
      SavedEntryDetailImageContent(
        image: image,
        fallbackSymbolName: "scribble.variable",
        imagePadding: 20
      )
    case .bauhaus(let image):
      SavedEntryDetailImageContent(
        image: image,
        fallbackSymbolName: "square.grid.3x3.square",
        imagePadding: 12
      )
    }
  }
}

/// Full text body for a saved text entry.
private struct SavedEntryDetailTextContent: View {

  let text: String

  var body: some View {
    Group {
      if text.isEmpty {
        Text("Untitled")
      } else {
        Text(text)
      }
    }
      .font(.title2.weight(.semibold))
      .lineSpacing(5)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// Large image well used by photo and doodle detail cards.
private struct SavedEntryDetailImageContent: View {

  let image: Image?
  let fallbackSymbolName: String
  let imagePadding: CGFloat

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: detailImageCornerRadius, style: .continuous)
        .fill(.appOnSecondaryContainer.opacity(0.06))

      if let image {
        image
          .resizable()
          .scaledToFit()
          .padding(imagePadding)
      } else {
        Image(systemName: fallbackSymbolName)
          .font(.system(size: 58, weight: .semibold))
          .foregroundStyle(.appOnSecondaryContainer.opacity(0.42))
      }
    }
    .aspectRatio(4 / 3, contentMode: .fit)
    .clipShape(RoundedRectangle(cornerRadius: detailImageCornerRadius, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: detailImageCornerRadius, style: .continuous)
        .strokeBorder(.appOnSecondaryContainer.opacity(0.08), lineWidth: 1)
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

/// The values a grid summary card needs, extracted from a `Card` so the view is
/// previewable from literals and never touches SwiftData directly.
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

/// The mutually-exclusive content variants shown by saved-entry cards.
private enum SavedEntryCardContent {
  /// A text capture; media captures never use this as a caption.
  case text(String)

  /// An audio capture, with the local media URL when the file is available.
  case audio(fileURL: URL?)

  /// A still image capture, backed by the best image currently available.
  case image(Image?)

  /// A doodle capture, backed by a rasterized thumbnail when available.
  case doodle(Image?)

  /// A Bauhaus grid artwork capture, backed by a rasterized thumbnail when available.
  case bauhaus(Image?)

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
        return .image(attachments.first(matching: .photo)?.thumbnailImage)
      case .audio:
        return .audio(fileURL: nil)
      case .doodle:
        return .doodle(attachments.first(matching: .doodle)?.thumbnailImage)
      case .bauhaus:
        return .bauhaus(attachments.first(matching: .bauhaus)?.thumbnailImage)
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
        return .image(attachments.first(matching: .photo)?.photoImage)
      case .audio:
        return .audio(fileURL: attachments.first(matching: .audio)?.mediaFileURL)
      case .doodle:
        return .doodle(attachments.first(matching: .doodle)?.thumbnailImage)
      case .bauhaus:
        return .bauhaus(attachments.first(matching: .bauhaus)?.thumbnailImage)
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

  fileprivate var thumbnailImage: Image? {
    thumbnail
      .flatMap(UIImage.init(data:))
      .map(Image.init(uiImage:))
  }

  fileprivate var photoImage: Image? {
    if let mediaFileURL,
      let data = try? Data(contentsOf: mediaFileURL),
      let image = UIImage(data: data)
    {
      return Image(uiImage: image)
    }

    return thumbnailImage
  }

  fileprivate var mediaFileURL: URL? {
    try? JournalStore.fileURL(for: self)
  }
}
