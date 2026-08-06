import CaptureDoodle
import MuColor
import SwiftUI

/// Doodle preview source for authored draft data or saved JSON media.
public struct DoodleContentSource: Equatable, Sendable {
  public let drawing: DoodleDrawing?
  public let fileURL: URL?
  public let fileRevision: Int
  public let thumbnailData: Data?
  public let displayAspectRatio: CGFloat?

  public init(
    drawing: DoodleDrawing? = nil,
    fileURL: URL? = nil,
    fileRevision: Int = 0,
    thumbnailData: Data? = nil,
    pixelSize: CGSize? = nil
  ) {
    self.drawing = drawing
    self.fileURL = fileURL
    self.fileRevision = fileRevision
    self.thumbnailData = thumbnailData
    // The authored canvas size doubles as the drawing's display geometry, so a
    // saved doodle can reserve its box before the JSON is read back.
    self.displayAspectRatio =
      pixelSize?.contentAspectRatio
      ?? drawing?.canvasSize.contentAspectRatio
  }
}

/// Renders authored doodle JSON or its persisted thumbnail fallback.
struct DoodleContentView: View {

  /// Visual treatment owned by vector doodle content.
  struct Style {
    let preset: EntryContentStyle

    init(_ preset: EntryContentStyle) {
      self.preset = preset
    }

    var displayAspectRatio: CGFloat? {
      switch preset {
      case .composer, .overview:
        return 1
      case .detail, .share:
        return nil
      }
    }

    var artworkPadding: CGFloat {
      switch preset {
      case .composer, .detail:
        return 0
      case .overview:
        return 10
      case .share:
        return 32
      }
    }

    var usesMediaWell: Bool { preset == .share }
    var usesCompactLoading: Bool { preset == .composer }
    var isDetail: Bool { preset == .detail }
    var placeholderAspectRatio: CGFloat { 1 }
    var minimumHeight: CGFloat? { preset == .detail ? 180 : nil }
  }

  let doodle: DoodleContentSource
  let style: Style

  @Environment(\.appPalette) private var palette
  @State private var state: ContentMediaLoadState<DoodleDrawing> = .idle

  var body: some View {
    content
      .detailMediaFrame(
        aspectRatio: displayAspectRatio,
        isDetail: style.isDetail
      )
      .contentMediaWell(isEnabled: style.usesMediaWell)
      .task(
        id: ContentFileLoadID(
          fileURL: doodle.fileURL,
          fileRevision: doodle.fileRevision
        )
      ) {
        await loadDrawing()
      }
  }

  /// Keeps the loading and rendered states on one placement geometry.
  ///
  /// Compact placements impose their own square, so only the unconstrained
  /// detail placement reserves the authored canvas geometry. Doodles saved
  /// before canvas dimensions were persisted still resize once decoded.
  private var displayAspectRatio: CGFloat {
    guard style.isDetail else {
      return style.placeholderAspectRatio
    }

    return
      doodle.displayAspectRatio
      ?? state.loadedPayload?.canvasSize.contentAspectRatio
      ?? style.placeholderAspectRatio
  }

  @ViewBuilder
  private var content: some View {
    if let drawing = doodle.drawing {
      rendered(drawing)
    } else {
      switch state {
      case .loaded(let drawing):
        rendered(drawing)
      case .loading:
        ContentLoadingMedia(isCompact: style.usesCompactLoading)
      case .idle, .unavailable:
        if style.preset == .share, doodle.thumbnailData != nil {
          SynchronousImageContentView(
            imageData: doodle.thumbnailData,
            fallbackSystemImage: "scribble"
          )
        } else {
          ContentMediaPlaceholder(
            systemImage: "scribble",
            aspectRatio: displayAspectRatio
          )
        }
      }
    }
  }

  @ViewBuilder
  private func rendered(_ drawing: DoodleDrawing) -> some View {
    DoodleDrawingView(
      drawing: drawing,
      inkColor: palette.tint,
      displayAspectRatio: style.displayAspectRatio
    )
    .padding(style.artworkPadding)
  }

  @MainActor
  private func loadDrawing() async {
    guard doodle.drawing == nil else {
      state = .idle
      return
    }

    guard let fileURL = doodle.fileURL else {
      state = .unavailable
      return
    }

    guard await ContentMediaFileReader.fileExists(at: fileURL) else {
      state = .unavailable
      return
    }

    state = .loading
    guard let data = await ContentMediaFileReader.data(from: fileURL),
      let drawing = try? JSONDecoder().decode(DoodleDrawing.self, from: data),
      Task.isCancelled == false
    else {
      state = .unavailable
      return
    }

    state = .loaded(drawing)
  }
}

#Preview("Doodle Content — 4:3") {
  EntryContentPreviewCanvas {
    DoodleContentView(
      doodle: DoodleContentSource(
        pixelSize: CGSize(width: 2_048, height: 1_536)
      ),
      style: .init(.detail)
    )
  }
}
