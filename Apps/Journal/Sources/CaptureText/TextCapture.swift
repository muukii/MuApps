#if os(iOS)
import NextGrowingTextViewSwiftUI
#endif
import SwiftUI

#if os(macOS)
/// Layout rules for Journal's native macOS growing multiline editor.
public struct GrowingTextEditorConfiguration: Sendable, Equatable {
  public var minLines: Int
  public var maxLines: Int?
  public var horizontalPadding: CGFloat
  public var verticalPadding: CGFloat
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
}

/// Native macOS multiline input matching the iOS package API used by Journal.
/// `TextField(axis: .vertical)` supplies pointer, selection, undo, and growing
/// line behavior without introducing a UIKit text view into the Mac product.
public struct GrowingTextEditor<Placeholder: View>: View {
  @Binding private var text: String
  private let configuration: GrowingTextEditorConfiguration
  private let font: Font?
  private let placeholder: Placeholder

  public init(
    text: Binding<String>,
    configuration: GrowingTextEditorConfiguration = .init(),
    font: Font? = nil,
    @ViewBuilder placeholder: () -> Placeholder
  ) {
    self._text = text
    self.configuration = configuration
    self.font = font
    self.placeholder = placeholder()
  }

  public var body: some View {
    ZStack(alignment: .topLeading) {
      if text.isEmpty {
        placeholder
          .foregroundStyle(.secondary)
          .padding(.horizontal, configuration.horizontalPadding)
          .padding(.vertical, configuration.verticalPadding)
          .allowsHitTesting(false)
      }

      TextField("", text: $text, axis: .vertical)
        .textFieldStyle(.plain)
        .font(font)
        .lineSpacing(configuration.lineSpacing)
        .lineLimit(configuration.minLines...(configuration.maxLines ?? 1_000))
        .padding(.horizontal, configuration.horizontalPadding)
        .padding(.vertical, configuration.verticalPadding)
    }
  }
}

public extension GrowingTextEditor where Placeholder == Text {
  init(
    text: Binding<String>,
    placeholder: String,
    configuration: GrowingTextEditorConfiguration = .init(),
    font: Font? = nil
  ) {
    self.init(text: text, configuration: configuration, font: font) {
      Text(placeholder)
    }
  }
}
#endif
