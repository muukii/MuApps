import MuColor
import SwiftUI

/// Renders a native link preview with a written-content fallback.
struct LinkContentView: View {

  /// Visual and interaction treatment owned by link content.
  struct Style {
    let preset: EntryContentStyle

    init(_ preset: EntryContentStyle) {
      self.preset = preset
    }

    /// Finite native-preview height for the natural-height Cell placement.
    ///
    /// The host intentionally has no intrinsic size because its native width
    /// can exceed a SwiftUI grid column. Compact placements already receive
    /// their geometry from their parent and must not be resized here.
    var previewHeight: CGFloat? {
      switch preset {
      case .cell:
        return 240
      case .composer:
        return nil
      }
    }

    var fallbackTextStyle: TextContentView.Style {
      .init(
        preset,
        emptyTitle: {
          switch preset {
          case .composer:
            return "Link"
          case .cell:
            return "Empty link"
          }
        }()
      )
    }

    var minimumHeight: CGFloat? {
      previewHeight
    }
  }

  let urlString: String
  let style: Style

  var body: some View {
    if let linkURL = JournalLinkURL(urlString) {
      JournalLinkPreview(
        url: linkURL.url,
      )
      .frame(height: style.previewHeight)
      .padding(16)
      .background(.appSecondaryContainer)
    } else {
      TextContentView(
        text: urlString,
        style: style.fallbackTextStyle
      )
    }
  }
}

#Preview("Link Content") {
  EntryContentPreviewCanvas {
    LinkContentView(
      urlString: "https://rivet.design/",
      style: .init(.cell)
    )
  }
}
