import CaptureBauhaus
import SwiftUI

/// Bauhaus preview source for authored draft data or saved JSON media.
public struct BauhausContentSource: Equatable, Sendable {
  public let document: BauhausGridDocument?
  public let fileURL: URL?
  public let fileRevision: Int
  public let thumbnailData: Data?

  public init(
    document: BauhausGridDocument? = nil,
    fileURL: URL? = nil,
    fileRevision: Int = 0,
    thumbnailData: Data? = nil
  ) {
    self.document = document
    self.fileURL = fileURL
    self.fileRevision = fileRevision
    self.thumbnailData = thumbnailData
  }
}

/// Renders an authored Bauhaus grid or its persisted thumbnail fallback.
struct BauhausContentView: View {

  /// Visual treatment owned by Bauhaus artwork content.
  struct Style {
    let preset: EntryContentStyle

    init(_ preset: EntryContentStyle) {
      self.preset = preset
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

  let bauhaus: BauhausContentSource
  let style: Style

  @State private var state: ContentMediaLoadState<BauhausGridDocument> =
    .idle

  var body: some View {
    content
      .task(
        id: ContentFileLoadID(
          fileURL: bauhaus.fileURL,
          fileRevision: bauhaus.fileRevision
        )
      ) {
        await loadDocument()
      }
  }

  @ViewBuilder
  private var content: some View {
    if let document = bauhaus.document {
      rendered(document)
    } else {
      switch state {
      case .loaded(let document):
        rendered(document)
      case .loading:
        ContentLoadingMedia(isCompact: style.usesCompactLoading)
      case .idle, .unavailable:
        if bauhaus.fileURL == nil, bauhaus.thumbnailData != nil {
          InlineImageDataContentView(
            imageData: bauhaus.thumbnailData,
            fallbackSystemImage: "square.grid.3x3.square"
          )
        } else {
          ContentMediaPlaceholder(
            systemImage: "square.grid.3x3",
            aspectRatio: style.placeholderAspectRatio
          )
        }
      }
    }
  }

  @ViewBuilder
  private func rendered(_ document: BauhausGridDocument) -> some View {
    BauhausGridArtworkView(
      padding: 20,
      artwork: document.artwork
    )
  }

  @MainActor
  private func loadDocument() async {
    guard bauhaus.document == nil else {
      state = .idle
      return
    }

    guard let fileURL = bauhaus.fileURL else {
      state = .unavailable
      return
    }

    guard await ContentMediaFileReader.fileExists(at: fileURL) else {
      state = .unavailable
      return
    }

    state = .loading
    guard let data = await ContentMediaFileReader.data(from: fileURL),
      let document = try? JSONDecoder().decode(
        BauhausGridDocument.self,
        from: data
      ),
      Task.isCancelled == false
    else {
      state = .unavailable
      return
    }

    state = .loaded(document)
  }
}

#Preview("Bauhaus Content") {
  EntryContentPreviewCanvas {
    BauhausContentView(
      bauhaus: BauhausContentSource(
        document: BauhausContentPreview.document
      ),
      style: .init(.cell)
    )
  }
}

/// A populated authored document for exercising the entry-content renderer.
///
/// This fixture stays local to the preview because it represents neither a
/// capture default nor persisted product content.
private enum BauhausContentPreview {

  static let document: BauhausGridDocument = {
    var artwork = BauhausGridArtwork()
    artwork[BauhausGridPosition(row: 0, column: 1)] = BauhausTile(
      shape: .circle,
      shapeSwatch: .slot1
    )
    artwork[BauhausGridPosition(row: 1, column: 3)] = BauhausTile(
      shape: .semicircleLeading,
      shapeSwatch: .slot5,
      backgroundSwatch: .slot2
    )
    artwork[BauhausGridPosition(row: 2, column: 0)] = BauhausTile(
      shape: .triangleBottomTrailing,
      shapeSwatch: .slot7,
      backgroundSwatch: .slot4
    )
    artwork[BauhausGridPosition(row: 2, column: 2)] = BauhausTile(
      shape: .square,
      shapeSwatch: .slot2
    )
    artwork[BauhausGridPosition(row: 3, column: 1)] = BauhausTile(
      shape: .quarterCircleTopTrailing,
      shapeSwatch: .slot6
    )
    artwork[BauhausGridPosition(row: 4, column: 4)] = BauhausTile(
      shape: .paddedCircle,
      shapeSwatch: .slot1,
      backgroundSwatch: .slot5
    )
    return BauhausGridDocument(artwork: artwork)
  }()
}
