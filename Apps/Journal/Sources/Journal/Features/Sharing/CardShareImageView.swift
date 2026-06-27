import JournalModel
import MuColor
import SwiftUI
import UIKit

/// Export-only layout for a single journal card.
///
/// This view is intentionally independent from the saved-list tile. Sharing has
/// a fixed canvas, stronger typography, and later needs to match video frames;
/// the list tile stays optimized for dense in-app browsing.
struct CardShareImageView: View {

  let snapshot: CardShareSnapshot
  let palette: Palette

  init(snapshot: CardShareSnapshot, palette: Palette = .default) {
    self.snapshot = snapshot
    self.palette = palette
  }

  var body: some View {
    CardShareExportFrame(snapshot: snapshot, palette: palette) {
      CardShareContentView(content: snapshot.content)
    }
  }
}

/// Export frame used as the static background for Doodle replay videos.
///
/// The moving stroke layer is intentionally omitted so the video writer can
/// render this SwiftUI frame once, then composite only the time-varying Doodle
/// vector content for each generated frame.
struct CardShareDoodleVideoBaseFrameView: View {

  let snapshot: CardShareSnapshot
  let palette: Palette

  init(snapshot: CardShareSnapshot, palette: Palette = .default) {
    self.snapshot = snapshot
    self.palette = palette
  }

  var body: some View {
    CardShareExportFrame(snapshot: snapshot, palette: palette) {
      CardShareDoodleVideoBaseContent()
    }
  }
}

/// Shared export canvas used by still-image and replay previews.
///
/// Keeping the outer frame here gives every share format the same themed
/// background, paper surface, header, and footer. The caller only swaps the main
/// content area.
struct CardShareExportFrame<Content: View>: View {

  let snapshot: CardShareSnapshot
  let palette: Palette

  private let content: Content

  init(
    snapshot: CardShareSnapshot,
    palette: Palette = .default,
    @ViewBuilder content: () -> Content
  ) {
    self.snapshot = snapshot
    self.palette = palette
    self.content = content()
  }

  var body: some View {
    PrimaryContainer(palette: palette) {
      ZStack {
        Rectangle()
          .fill(.appPrimaryContainer)

        CardSharePaper(snapshot: snapshot, content: content)
          .padding(72)
      }
    }
  }
}

/// The paper surface and content stack used by the exported image.
private struct CardSharePaper<Content: View>: View {

  let snapshot: CardShareSnapshot
  let content: Content

  var body: some View {
    RoundedRectangle(cornerRadius: 44, style: .continuous)
      .fill(.appSecondaryContainer)
      .overlay {
        VStack(alignment: .leading, spacing: 36) {
          CardShareHeader(kind: snapshot.kind, createdAt: snapshot.createdAt)

          content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

          CardShareFooter(location: snapshot.location)
        }
        .padding(56)
        .foregroundStyle(.appOnSecondaryContainer)
      }
      .shadow(color: .black.opacity(0.16), radius: 28, x: 0, y: 18)
  }
}

/// Empty Doodle content well used by the static video base frame.
private struct CardShareDoodleVideoBaseContent: View {

  var body: some View {
    RoundedRectangle(cornerRadius: 32, style: .continuous)
      .fill(.appOnSecondaryContainer.opacity(0.06))
      .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
  }
}

/// Kind and timestamp row shown at the top of the export.
private struct CardShareHeader: View {

  let kind: Card.Kind
  let createdAt: Date

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 18) {
      Label {
        Text(kind.shareTitle)
      } icon: {
        Image(systemName: kind.shareSymbolName)
      }
      .font(.system(size: 30, weight: .semibold))
      .labelStyle(.titleAndIcon)

      Spacer(minLength: 0)

      Text(createdAt, format: .dateTime.year().month().day().hour().minute())
        .font(.system(size: 24, weight: .medium))
        .foregroundStyle(.appOnSecondaryContainer.opacity(0.56))
    }
  }
}

/// Routes the share payload to its visual representation.
private struct CardShareContentView: View {

  let content: CardShareContent

  var body: some View {
    switch content {
    case .text(let text):
      CardShareTextContent(text: text)
    case .photo(let imageData):
      CardShareImageContent(imageData: imageData, fallbackSymbolName: "photo")
    case .audio(let fileURL):
      CardShareAudioContent(hasFile: fileURL != nil)
    case .doodle(_, let thumbnailData):
      CardShareImageContent(imageData: thumbnailData, fallbackSymbolName: "scribble.variable")
    case .bauhaus(_, let thumbnailData):
      CardShareImageContent(imageData: thumbnailData, fallbackSymbolName: "square.grid.3x3.square")
    }
  }
}

/// Large, readable note body for text-card exports.
private struct CardShareTextContent: View {

  let text: String

  var body: some View {
    Text(text.isEmpty ? "Untitled" : text)
      .font(.system(size: 64, weight: .bold))
      .lineSpacing(8)
      .lineLimit(10)
      .minimumScaleFactor(0.62)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}

/// Photo and doodle preview area for image-based exports.
private struct CardShareImageContent: View {

  let imageData: Data?
  let fallbackSymbolName: String

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 32, style: .continuous)
        .fill(.appOnSecondaryContainer.opacity(0.06))

      if let image {
        image
          .resizable()
          .scaledToFit()
          .padding(32)
      } else {
        Image(systemName: fallbackSymbolName)
          .font(.system(size: 108, weight: .semibold))
          .foregroundStyle(.appOnSecondaryContainer.opacity(0.42))
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
  }

  private var image: Image? {
    imageData
      .flatMap(UIImage.init(data:))
      .map(Image.init(uiImage:))
  }
}

/// Audio export placeholder until waveform metadata is persisted.
private struct CardShareAudioContent: View {

  let hasFile: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 36) {
      Image(systemName: "waveform")
        .font(.system(size: 96, weight: .semibold))

      HStack(alignment: .center, spacing: 10) {
        ForEach(Self.samples) { sample in
          Capsule()
            .fill(.appOnSecondaryContainer.opacity(hasFile ? 0.44 : 0.22))
            .frame(width: 16, height: 32 + sample.level * 132)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
  }

  private static let samples: [CardShareWaveformSample] = [
    .init(id: 0, level: 0.22),
    .init(id: 1, level: 0.58),
    .init(id: 2, level: 0.36),
    .init(id: 3, level: 0.84),
    .init(id: 4, level: 0.52),
    .init(id: 5, level: 0.72),
    .init(id: 6, level: 0.30),
    .init(id: 7, level: 0.78),
    .init(id: 8, level: 0.46),
    .init(id: 9, level: 0.64),
  ]
}

/// One deterministic bar in the exported audio placeholder.
private struct CardShareWaveformSample: Identifiable {
  let id: Int
  let level: CGFloat
}

/// Optional metadata row at the bottom of the export.
private struct CardShareFooter: View {

  let location: Coordinate?

  var body: some View {
    HStack(spacing: 10) {
      Text("Journal")

      if location != nil {
        Image(systemName: "location.fill")
      }
    }
    .font(.system(size: 24, weight: .semibold))
    .foregroundStyle(.appOnSecondaryContainer.opacity(0.52))
  }
}

private extension Card.Kind {

  var shareTitle: LocalizedStringResource {
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

  var shareSymbolName: String {
    switch self {
    case .text:
      return "text.alignleft"
    case .photo:
      return "photo"
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
