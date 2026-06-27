import JournalModel
import MuColor
import SwiftData
import SwiftUI
import UIKit

/// SwiftData + iCloud entries list.
///
/// Cards are laid out as a two-column grid of portrait tiles shaped like a sheet
/// of paper (1 : 1.4144, via `CardSurface`). Each tile renders one captured
/// modality — text, audio, image, or doodle — because a captured thing becomes
/// its own Card rather than media-with-caption.
struct SavedListView: View {

  @Environment(\.modelContext) private var modelContext
  @Query(sort: \Card.createdAt, order: .reverse) private var cards: [Card]

  private let columns = [
    GridItem(.flexible(), spacing: cardSpacing),
    GridItem(.flexible(), spacing: cardSpacing),
  ]

  var body: some View {
    ScrollView {
      LazyVGrid(columns: columns, spacing: cardSpacing) {
        ForEach(cards) { card in
          CardTile(display: card.tileDisplay)
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
  }
}

/// Gutter between cards and around the grid, kept equal so columns and edges
/// share the same rhythm.
private let cardSpacing: CGFloat = 16

/// Maximum absolute tilt for a card, in degrees. Each tile picks a stable angle
/// in `-cardMaxTilt ... +cardMaxTilt` from its id, giving the grid a loosely
/// hand-placed feel rather than a rigid one.
private let cardMaxTilt: Double = 3

// MARK: - Fileprivate Views

/// A single journal card rendered as a portrait tile. Shares the paper look with
/// the compose surface via `CardSurface`; receives already-extracted display
/// values so it stays previewable from literals and never touches SwiftData.
private struct CardTile: View {

  let display: CardDisplay

  var body: some View {
    CardSurface {
      VStack(alignment: .leading, spacing: 10) {
        CardTileContent(content: display.content)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

        CardTileFooter(date: display.date, kind: display.content.kind)
      }
    }
    .rotationEffect(display.tilt)
    .accessibilityElement(children: .combine)
  }
}

/// The modality-specific body of a card. The outer tile keeps the chrome and
/// footer consistent; this view owns the one place where text/audio/image/doodle
/// intentionally diverge.
private struct CardTileContent: View {

  let content: CardContent

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      switch content {
      case .text(let text):
        Text(text.isEmpty ? "Untitled" : text)
          .font(.callout)
          .lineLimit(9)
          .multilineTextAlignment(.leading)
          .minimumScaleFactor(0.9)
          .frame(maxWidth: .infinity, alignment: .leading)
      case .audio:
        AudioCardContent()
      case .image(let image):
        ImageCardContent(image: image)
      case .doodle(let image):
        DoodleCardContent(image: image)
      }
    }
  }
}

/// Footer shared by every tile: timestamp plus the card's single modality icon.
private struct CardTileFooter: View {

  let date: Date
  let kind: Card.Kind

  var body: some View {
    HStack(spacing: 6) {
      Text(date, format: .relative(presentation: .named))
        .lineLimit(1)

      Spacer(minLength: 0)

      Image(systemName: kind.symbolName)
    }
    .font(.caption2)
    .foregroundStyle(.appOnSecondaryContainer.opacity(0.55))
  }
}

/// Text-free audio card content. The waveform is decorative: real playback UI
/// can grow here later without changing text/image/doodle tile layout.
private struct AudioCardContent: View {

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

      AudioWaveformPreview()
        .frame(height: 56)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}

/// Static waveform skeleton for audio-only cards. Uses fixed sample ids so
/// preview/list identity stays stable across body evaluations.
private struct AudioWaveformPreview: View {

  private static let samples: [AudioWaveformSample] = [
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
          .fill(.appOnSecondaryContainer.opacity(0.34))
          .frame(width: 4, height: 10 + sample.level * 42)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
  }
}

private struct AudioWaveformSample: Identifiable {
  let id: Int
  let level: CGFloat
}

/// Photo/image cards use their thumbnail as the whole visual body.
private struct ImageCardContent: View {

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
private struct DoodleCardContent: View {

  let image: Image?

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
        Image(systemName: "scribble.variable")
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

/// The values a `CardTile` needs, extracted from a `Card` so the view is cheap to
/// construct (and previewable) and the SwiftData entity never leaks into it.
private struct CardDisplay: Identifiable {
  let id: UUID
  /// Exactly one visual/content modality for the card.
  let content: CardContent
  let date: Date
  let tilt: Angle
}

/// The mutually-exclusive card body variants shown in the entries grid.
private enum CardContent {
  /// A text capture; media captures never use this as a caption.
  case text(String)
  /// An audio capture represented by its modality chrome until real playback UI exists.
  case audio
  /// A still image capture, backed by a thumbnail when available.
  case image(Image?)
  /// A doodle capture, backed by a rasterized thumbnail when available.
  case doodle(Image?)

  var kind: Card.Kind {
    switch self {
    case .text: .text
    case .audio: .audio
    case .image: .photo
    case .doodle: .doodle
    }
  }
}

// MARK: - Formatting Helpers

extension Card {
  fileprivate var tileDisplay: CardDisplay {
    let attachments = (attachments ?? []).sorted { $0.createdAt < $1.createdAt }
    let content: CardContent = {
      switch kind {
      case .text:
        return .text(body.trimmingCharacters(in: .whitespacesAndNewlines))
      case .photo:
        return .image(attachments.first(matching: .photo)?.thumbnailImage)
      case .audio:
        return .audio
      case .doodle:
        return .doodle(attachments.first(matching: .doodle)?.thumbnailImage)
      @unknown default:
        return .text(body.trimmingCharacters(in: .whitespacesAndNewlines))
      }
    }()

    return CardDisplay(
      id: id,
      content: content,
      date: createdAt,
      tilt: tiltAngle
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

  /// SF Symbol shown in the footer for this card pattern.
  fileprivate var symbolName: String {
    switch self {
    case .text: "text.alignleft"
    case .photo: "photo"
    case .audio: "waveform"
    case .doodle: "scribble.variable"
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
}
