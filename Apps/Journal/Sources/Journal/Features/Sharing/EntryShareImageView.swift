import AppUIComponents
import JournalVault
import MuColor
import SwiftUI

/// Export-only layout for one saved entry.
///
/// This view is intentionally independent from the saved-list tile. Sharing has
/// a fixed canvas, stronger typography, and later needs to match video frames;
/// the list tile stays optimized for dense in-app browsing.
struct EntryShareImageView: View {

  let snapshot: EntryShareSnapshot
  let palette: Palette

  init(snapshot: EntryShareSnapshot, palette: Palette = .default) {
    self.snapshot = snapshot
    self.palette = palette
  }

  var body: some View {
    EntryShareExportFrame(snapshot: snapshot, palette: palette) {
      EntryContentView(content: snapshot.content, style: .share)
    }
  }
}

/// Export frame used as the static background for Doodle replay videos.
///
/// The moving stroke layer is intentionally omitted so the video writer can
/// render this SwiftUI frame once, then composite only the time-varying Doodle
/// vector content for each generated frame.
struct EntryShareDoodleVideoBaseFrameView: View {

  let snapshot: EntryShareSnapshot
  let palette: Palette

  init(snapshot: EntryShareSnapshot, palette: Palette = .default) {
    self.snapshot = snapshot
    self.palette = palette
  }

  var body: some View {
    EntryShareExportFrame(snapshot: snapshot, palette: palette) {
      EntryShareReplayVideoBaseContent()
    }
  }
}

/// Shared export canvas used by still-image and replay previews.
///
/// The canvas provides shared branding and metadata while each authored content
/// style owns its actual visual treatment.
struct EntryShareExportFrame<Content: View>: View {

  let snapshot: EntryShareSnapshot
  let palette: Palette

  private let content: Content

  init(
    snapshot: EntryShareSnapshot,
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
          .fill(.appSecondaryContainer)

        VStack(alignment: .leading, spacing: 36) {
          EntryShareHeader(kind: snapshot.kind, createdAt: snapshot.createdAt)

          content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

          EntryShareFooter(location: snapshot.location)
        }
        .padding(96)
        .foregroundStyle(.appOnSecondaryContainer)
      }
    }
  }
}

/// Export frame used as the static background for Bauhaus replay videos.
///
/// The animated grid is drawn by the video writer, while this view keeps the
/// surrounding share chrome identical to image export.
struct EntryShareBauhausVideoBaseFrameView: View {

  let snapshot: EntryShareSnapshot
  let palette: Palette

  init(snapshot: EntryShareSnapshot, palette: Palette = .default) {
    self.snapshot = snapshot
    self.palette = palette
  }

  var body: some View {
    EntryShareExportFrame(snapshot: snapshot, palette: palette) {
      EntryShareReplayVideoBaseContent()
    }
  }
}

/// Empty media well used by static video base frames.
private struct EntryShareReplayVideoBaseContent: View {

  var body: some View {
    RoundedRectangle(cornerRadius: 32, style: .continuous)
      .fill(.appOnSecondaryContainer.opacity(0.06))
      .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
  }
}

/// Kind and timestamp row shown at the top of the export.
private struct EntryShareHeader: View {

  let kind: JournalVault.Card.Kind
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

/// Optional metadata row at the bottom of the export.
private struct EntryShareFooter: View {

  let location: JournalVault.Coordinate?

  var body: some View {
    HStack(spacing: 10) {
      Text("Tinycurve")

      if location != nil {
        Image(systemName: "location.fill")
      }
    }
    .font(.system(size: 24, weight: .semibold))
    .foregroundStyle(.appOnSecondaryContainer.opacity(0.52))
  }
}

extension JournalVault.Card.Kind {

  fileprivate var shareTitle: LocalizedStringResource {
    switch self {
    case .text:
      return "Text"
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

  fileprivate var shareSymbolName: String {
    switch self {
    case .text:
      return "text.alignleft"
    case .link:
      return "link"
    case .file:
      return "doc"
    case .photo:
      return "photo"
    case .video:
      return "video"
    case .livePhoto:
      return "livephoto"
    case .audio:
      return "waveform"
    case .suggestion:
      return "sparkles"
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

#Preview("Entry Share Text") {
  EntryShareImageView(
    snapshot: EntryShareSnapshot(
      id: UUID(uuidString: "D86B20CE-D183-47D8-9795-552F6B00C40B")!,
      kind: .text,
      createdAt: Date(timeIntervalSinceReferenceDate: 805_766_400),
      content: .text("A quiet morning, warm light, and a thought worth keeping."),
      location: JournalVault.Coordinate(
        latitude: 35.6812,
        longitude: 139.7671
      )
    )
  )
  .frame(
    width: EntryShareImageRenderer.defaultPixelSize.width,
    height: EntryShareImageRenderer.defaultPixelSize.height
  )
}
