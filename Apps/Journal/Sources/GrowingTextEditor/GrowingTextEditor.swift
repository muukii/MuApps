import SwiftUI

/// Layout rules for a `TextEditor` that grows with its text content.
///
/// The editor stays at `minLines` while short or empty, expands as text wraps,
/// and caps at `maxLines` when provided. Once capped, SwiftUI's `TextEditor`
/// owns the inner scrolling behavior.
public struct GrowingTextEditorConfiguration: Sendable, Equatable {

  /// The smallest number of visual lines the editor should reserve.
  public var minLines: Int

  /// The largest number of visual lines before the editor starts scrolling.
  ///
  /// Use `nil` for an uncapped editor that keeps expanding with its content.
  public var maxLines: Int?

  /// Horizontal space applied around both the visible editor and the hidden
  /// measuring editor.
  public var horizontalPadding: CGFloat

  /// Vertical space applied around both the visible editor and the hidden
  /// measuring editor.
  public var verticalPadding: CGFloat

  /// Extra spacing inserted between rendered text lines.
  public var lineSpacing: CGFloat

  public init(
    minLines: Int = 1,
    maxLines: Int? = nil,
    horizontalPadding: CGFloat = 5,
    verticalPadding: CGFloat = 8,
    lineSpacing: CGFloat = 0
  ) {
    let resolvedMinLines = Swift.max(1, minLines)
    self.minLines = resolvedMinLines
    self.maxLines = maxLines.map { Swift.max(resolvedMinLines, $0) }
    self.horizontalPadding = horizontalPadding
    self.verticalPadding = verticalPadding
    self.lineSpacing = lineSpacing
  }

  var contentInsets: EdgeInsets {
    EdgeInsets(
      top: verticalPadding,
      leading: horizontalPadding,
      bottom: verticalPadding,
      trailing: horizontalPadding
    )
  }
}

/// A pure SwiftUI growing text input built on top of `TextEditor`.
///
/// The implementation measures a hidden, non-scrolling `TextEditor` with the
/// same font, line spacing, and padding as the visible editor, then applies the
/// measured height back to the visible `TextEditor`. It intentionally does not
/// bridge to `UITextView`, which means UIKit-only hooks such as content offset
/// control and flashing scroll indicators are outside this component's contract.
public struct GrowingTextEditor<Placeholder: View>: View {

  @Binding private var text: String

  @Environment(\.font) private var environmentFont
  @State private var measurements = GrowingTextEditorMeasurements()

  private let configuration: GrowingTextEditorConfiguration
  private let explicitFont: Font?
  private let placeholder: Placeholder

  public init(
    text: Binding<String>,
    configuration: GrowingTextEditorConfiguration = GrowingTextEditorConfiguration(),
    font: Font? = nil,
    @ViewBuilder placeholder: () -> Placeholder
  ) {
    self._text = text
    self.configuration = configuration
    self.explicitFont = font
    self.placeholder = placeholder()
  }

  public var body: some View {
    ZStack(alignment: .topLeading) {
      if text.isEmpty {
        placeholder
          .foregroundStyle(.secondary)
          .padding(placeholderInsets)
          .allowsHitTesting(false)
          .accessibilityHidden(true)
      }

      editor
        .frame(height: resolvedHeight)
    }
    .background(alignment: .topLeading) {
      measurementLayer
    }
    .onPreferenceChange(GrowingTextEditorHeightPreferenceKey.self) { values in
      measurements.update(with: values)
    }
  }

  @ViewBuilder
  private var editor: some View {
    TextEditor(text: $text)
      .font(resolvedFont)
      .lineSpacing(configuration.lineSpacing)
      .scrollContentBackground(.hidden)
      .padding(configuration.contentInsets)
  }

  private var measurementLayer: some View {
    ZStack(alignment: .topLeading) {
      measurementEditor(
        GrowingTextEditorMeasurementText.content(for: text),
        role: .content
      )
      measurementEditor(
        GrowingTextEditorMeasurementText.lines(configuration.minLines),
        role: .minimum
      )
      if let maxLines = configuration.maxLines {
        measurementEditor(
          GrowingTextEditorMeasurementText.lines(maxLines),
          role: .maximum
        )
      }
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  private func measurementEditor(
    _ value: String,
    role: GrowingTextEditorMeasurementRole
  ) -> some View {
    TextEditor(text: .constant(value))
      .font(resolvedFont)
      .lineSpacing(configuration.lineSpacing)
      .scrollContentBackground(.hidden)
      .scrollDisabled(true)
      .padding(configuration.contentInsets)
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .fixedSize(horizontal: false, vertical: true)
      .hidden()
      .readGrowingTextEditorHeight(for: role)
  }

  private var resolvedFont: Font {
    explicitFont ?? environmentFont ?? .body
  }

  private var placeholderInsets: EdgeInsets {
    EdgeInsets(
      top: configuration.verticalPadding + GrowingTextEditorTextEditorInset.top,
      leading: configuration.horizontalPadding + GrowingTextEditorTextEditorInset.leading,
      bottom: configuration.verticalPadding + GrowingTextEditorTextEditorInset.bottom,
      trailing: configuration.horizontalPadding + GrowingTextEditorTextEditorInset.trailing
    )
  }

  private var resolvedHeight: CGFloat {
    let minimum = measurements.minimum ?? measurements.content ?? 1
    let content = Swift.max(measurements.content ?? minimum, minimum)

    if let maximum = measurements.maximum {
      return Swift.min(content, Swift.max(maximum, minimum))
    } else {
      return content
    }
  }
}

public extension GrowingTextEditor where Placeholder == EmptyView {

  /// Creates an editor without placeholder content.
  init(
    text: Binding<String>,
    configuration: GrowingTextEditorConfiguration = GrowingTextEditorConfiguration(),
    font: Font? = nil
  ) {
    self._text = text
    self.configuration = configuration
    self.explicitFont = font
    self.placeholder = EmptyView()
  }
}

public extension GrowingTextEditor where Placeholder == Text {

  /// Creates an editor with a localizable text placeholder.
  init(
    text: Binding<String>,
    placeholder: LocalizedStringKey,
    configuration: GrowingTextEditorConfiguration = GrowingTextEditorConfiguration(),
    font: Font? = nil
  ) {
    self._text = text
    self.configuration = configuration
    self.explicitFont = font
    self.placeholder = Text(placeholder)
  }
}

private struct GrowingTextEditorMeasurements: Equatable {
  var content: CGFloat?
  var minimum: CGFloat?
  var maximum: CGFloat?

  mutating func update(with values: [GrowingTextEditorMeasurementRole: CGFloat]) {
    content = values[.content] ?? content
    minimum = values[.minimum] ?? minimum
    maximum = values[.maximum] ?? maximum
  }
}

private enum GrowingTextEditorMeasurementRole: Hashable {
  case content
  case minimum
  case maximum
}

private enum GrowingTextEditorTextEditorInset {
  /// Approximate default inset SwiftUI's `TextEditor` keeps between its outer
  /// bounds and first rendered glyph. SwiftUI does not expose this value, so the
  /// placeholder uses the same small adjustment the previous Journal editor
  /// applied by hand.
  static let top: CGFloat = 8
  static let leading: CGFloat = 4
  static let bottom: CGFloat = 8
  static let trailing: CGFloat = 4
}

private enum GrowingTextEditorMeasurementText {

  static func content(for text: String) -> String {
    let value = text.isEmpty ? " " : text

    if value.hasSuffix("\n") {
      return value + " "
    } else {
      return value
    }
  }

  static func lines(_ count: Int) -> String {
    Array(repeating: " ", count: Swift.max(1, count)).joined(separator: "\n")
  }
}

private struct GrowingTextEditorHeightPreferenceKey: PreferenceKey {
  static let defaultValue: [GrowingTextEditorMeasurementRole: CGFloat] = [:]

  static func reduce(
    value: inout [GrowingTextEditorMeasurementRole: CGFloat],
    nextValue: () -> [GrowingTextEditorMeasurementRole: CGFloat]
  ) {
    value.merge(nextValue(), uniquingKeysWith: { _, new in new })
  }
}

private extension View {

  func readGrowingTextEditorHeight(for role: GrowingTextEditorMeasurementRole) -> some View {
    background {
      GeometryReader { proxy in
        Color.clear.preference(
          key: GrowingTextEditorHeightPreferenceKey.self,
          value: [role: proxy.size.height]
        )
      }
    }
  }
}

#Preview {
  GrowingTextEditorPreviewHost()
    .padding()
}

#Preview("TextEditor Fixed Size Measurement") {
  GrowingTextEditorMeasurementComparisonHost()
    .padding()
}

private struct GrowingTextEditorPreviewHost: View {

  @State private var emptyText = ""
  @State private var filledText = "Write something..."

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Placeholder")
        .font(.caption.weight(.semibold))

      GrowingTextEditor(
        text: $emptyText,
        placeholder: "Write something...",
        configuration: GrowingTextEditorConfiguration(
          minLines: 1,
          maxLines: 6,
          horizontalPadding: 8,
          verticalPadding: 4,
          lineSpacing: 3
        ),
        font: .body
      )
      .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))

      Text("Typed text")
        .font(.caption.weight(.semibold))

      GrowingTextEditor(
        text: $filledText,
        placeholder: "Write something...",
        configuration: GrowingTextEditorConfiguration(
          minLines: 1,
          maxLines: 6,
          horizontalPadding: 12,
          verticalPadding: 10,
          lineSpacing: 3
        ),
        font: .body
      )
      .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
  }
}

private struct GrowingTextEditorMeasurementComparisonHost: View {

  @State private var text = """
  A dummy TextEditor with fixedSize and scrollDisabled can expose its content
  height. This preview compares it with a Text-based approximation.
  """

  private let configuration = GrowingTextEditorConfiguration(
    minLines: 1,
    maxLines: 8,
    horizontalPadding: 12,
    verticalPadding: 10,
    lineSpacing: 3
  )
  private let editorFont: Font = .body

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        GrowingTextEditorMeasurementHeader()

        GrowingTextEditor(
          text: $text,
          placeholder: "Edit the shared sample...",
          configuration: configuration,
          font: editorFont
        )
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))

        GrowingTextEditorMeasurementRow(title: "Text measurement") {
          Text(GrowingTextEditorMeasurementText.content(for: text))
            .font(editorFont)
            .lineSpacing(configuration.lineSpacing)
            .padding(configuration.contentInsets)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
        }

        GrowingTextEditorMeasurementRow(title: "TextEditor.fixedSize + scrollDisabled measurement") {
          TextEditor(text: .constant(text))
            .font(editorFont)
            .lineSpacing(configuration.lineSpacing)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .padding(configuration.contentInsets)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
            .allowsHitTesting(false)
        }
      }
      .padding()
    }
  }
}

private struct GrowingTextEditorMeasurementHeader: View {

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Measurement Probe")
        .font(.headline)

      Text("Both rows receive the same text, font, line spacing, and outer padding. The TextEditor row uses scrollDisabled(true) before fixedSize.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }
}

private struct GrowingTextEditorMeasurementRow<Content: View>: View {

  let title: String
  let content: Content

  @State private var height: CGFloat?

  init(
    title: String,
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(title)
          .font(.caption.weight(.semibold))

        Spacer(minLength: 0)

        Text(heightLabel)
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }

      content
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(8)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
          RoundedRectangle(cornerRadius: 8)
            .stroke(.secondary.opacity(0.22), lineWidth: 1)
        }
        .readGrowingTextEditorPreviewHeight()
    }
    .onPreferenceChange(GrowingTextEditorPreviewHeightPreferenceKey.self) { value in
      height = value
    }
  }

  private var heightLabel: String {
    guard let height else {
      return "--"
    }

    return "\(Int(height.rounded())) pt"
  }
}

private struct GrowingTextEditorPreviewHeightPreferenceKey: PreferenceKey {
  static let defaultValue: CGFloat? = nil

  static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
    value = nextValue() ?? value
  }
}

private extension View {

  func readGrowingTextEditorPreviewHeight() -> some View {
    background {
      GeometryReader { proxy in
        Color.clear.preference(
          key: GrowingTextEditorPreviewHeightPreferenceKey.self,
          value: proxy.size.height
        )
      }
    }
  }
}
