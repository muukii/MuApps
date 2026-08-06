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

    var artworkPadding: CGFloat {
      switch preset {
      case .composer, .detail:
        return 0
      case .overview:
        return 8
      case .share:
        return 32
      }
    }

    var usesMediaWell: Bool { preset == .share }
    var usesCompactLoading: Bool { preset == .composer }
    var placeholderAspectRatio: CGFloat { 1 }
    var minimumHeight: CGFloat? { preset == .detail ? 180 : nil }
  }

  let bauhaus: BauhausContentSource
  let style: Style

  @State private var state: ContentMediaLoadState<BauhausGridDocument> =
    .idle

  var body: some View {
    content
      .contentMediaWell(isEnabled: style.usesMediaWell)
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
        if style.preset == .share, bauhaus.thumbnailData != nil {
          SynchronousImageContentView(
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
    BauhausGridArtworkView(artwork: document.artwork)
      .padding(style.artworkPadding)
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
      bauhaus: BauhausContentSource(),
      style: .init(.detail)
    )
  }
}
