import CaptureDoodle
import MuColor
import SwiftUI

/// Doodle preview source for authored draft data or saved JSON media.
public struct DoodleContentSource: Equatable, Sendable {
  public let drawing: DoodleDrawing?
  public let fileURL: URL?
  public let fileRevision: Int
  public let displayAspectRatio: CGFloat?

  public init(
    drawing: DoodleDrawing? = nil,
    fileURL: URL? = nil,
    fileRevision: Int = 0,
    pixelSize: CGSize? = nil
  ) {
    self.drawing = drawing
    self.fileURL = fileURL
    self.fileRevision = fileRevision
    // The authored canvas size doubles as the drawing's display geometry, so a
    // saved doodle can reserve its box before the JSON is read back.
    self.displayAspectRatio =
      pixelSize?.contentAspectRatio
      ?? drawing?.canvasSize.contentAspectRatio
  }
}

/// Renders authored doodle JSON from a draft value or saved media resource.
struct DoodleContentView: View {

  /// Visual treatment owned by vector doodle content.
  struct Style {
    let preset: EntryContentStyle

    init(_ preset: EntryContentStyle) {
      self.preset = preset
    }

    var displayAspectRatio: CGFloat? {
      switch preset {
      case .composer:
        return 1
      case .cell:
        return nil
      }
    }

    var usesCompactLoading: Bool {
      switch preset {
      case .composer:
        return true
      case .cell:
        return false
      }
    }

    var placeholderAspectRatio: CGFloat { 1 }
  }

  let doodle: DoodleContentSource
  let style: Style

  @Environment(\.appPalette) private var palette
  @State private var state: ContentMediaLoadState<DoodleDrawing> = .idle

  var body: some View {
    ContentMediaFrame(aspectRatio: displayAspectRatio) {
      content
        .background(.appSecondaryContainer)
    }
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
  /// Composer previews use a square while a Cell reserves the authored canvas
  /// geometry. Persisted metadata keeps compatible older drawings at their
  /// recorded ratio; missing metadata uses the fixed authored ratio without
  /// waiting for JSON decoding.
  private var displayAspectRatio: CGFloat {
    switch style.preset {
    case .composer:
      return style.placeholderAspectRatio
    case .cell:
      return doodle.displayAspectRatio ?? DoodleDrawing.canvasAspectRatio
    }
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
        ContentMediaPlaceholder(
          systemImage: "scribble",
          aspectRatio: displayAspectRatio
        )
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
      style: .init(.cell)
    )
  }
}
