import SwiftUI

/// Renders a placeholder for content authored by an unrecognized app version.
struct UnknownContentView: View {

  /// Visual treatment owned by content from a newer, unrecognized app version.
  struct Style {
    let preset: EntryContentStyle

    init(_ preset: EntryContentStyle) {
      self.preset = preset
    }

    var minimumHeight: CGFloat? { preset == .detail ? 120 : nil }
  }

  let style: Style

  var body: some View {
    if style.preset == .composer {
      ContentMediaPlaceholder(
        systemImage: "questionmark.square.dashed",
        aspectRatio: 1
      )
    } else {
      ContentMediaPlaceholder(systemImage: "questionmark.square.dashed")
    }
  }
}

#Preview("Unknown Content") {
  EntryContentPreviewCanvas {
    UnknownContentView(style: .init(.detail))
  }
}
