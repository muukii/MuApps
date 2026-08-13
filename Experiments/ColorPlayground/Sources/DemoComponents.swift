import SwiftUI

// MARK: - Reusable demo chrome
//
// These three helpers are used by every demo screen, so they earn their keep
// as shared components (see coding-guide: abstract obvious cross-cutting reuse).

/// A titled, padded surface used to group one concept on a demo screen.
///
/// Its chrome uses a concrete `Color(.secondarySystemBackground)` on purpose —
/// NOT the `.background` ShapeStyle — so that the backgroundStyle demos can
/// override `.background` inside a card without the card itself moving.
struct SectionCard<Content: View>: View {
  let title: String
  let subtitle: String?
  @ViewBuilder let content: Content

  init(
    title: String,
    subtitle: String? = nil,
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.subtitle = subtitle
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      VStack(alignment: .leading, spacing: 4) {
        Text(title)
          .font(.headline)
        if let subtitle {
          Text(subtitle)
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
      }
      content
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(16)
    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
  }
}

/// A fixed-height swatch with a monospaced caption describing the exact code
/// that produced it. The caption is the teaching surface — read it, then look up.
struct Tile<Content: View>: View {
  let caption: String
  @ViewBuilder let content: Content

  init(caption: String, @ViewBuilder content: () -> Content) {
    self.caption = caption
    self.content = content()
  }

  var body: some View {
    VStack(spacing: 6) {
      content
        .frame(maxWidth: .infinity)
        .frame(height: 56)
      Text(caption)
        .font(.system(.caption2, design: .monospaced))
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

/// A selectable, monospaced code line for inline snippets.
struct CodeText: View {
  let code: String

  init(_ code: String) {
    self.code = code
  }

  var body: some View {
    Text(code)
      .font(.system(.caption, design: .monospaced))
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(10)
      .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
      .textSelection(.enabled)
  }
}
