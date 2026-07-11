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

// MARK: - Value

/// A captured text note. Plain value type — the host decides how to persist it.
public struct CapturedText: Sendable, Equatable {
  public var text: String

  public init(text: String) {
    self.text = text
  }

  public var isEmpty: Bool {
    text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
}

// MARK: - Capture View

/// A self-contained multiline text editor. Emits the edited text through
/// `onCommit`; owns no persistence and knows nothing about Card.
public struct TextCaptureView: View {

  @State private var text: String
  @FocusState private var isFocused: Bool

  private let placeholder: String
  private let onCommit: @MainActor @Sendable (CapturedText) -> Void

  public init(
    initialText: String = "",
    placeholder: String = "What's on your mind?",
    onCommit: @escaping @MainActor @Sendable (CapturedText) -> Void
  ) {
    self._text = State(initialValue: initialText)
    self.placeholder = placeholder
    self.onCommit = onCommit
  }

  public var body: some View {
    GrowingTextEditor(
      text: $text,
      configuration: GrowingTextEditorConfiguration(
        minLines: 4,
        maxLines: 12,
        horizontalPadding: 16,
        verticalPadding: 16
      ),
      font: .system(size: 32, weight: .bold)
    ) {
      Text(placeholder)
    }
    .focused($isFocused)
    .foregroundStyle(.primary)
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button("Save") {
          onCommit(CapturedText(text: text))
        }
        .disabled(CapturedText(text: text).isEmpty)
      }
      ToolbarItem(placement: .keyboard) {
        Spacer()
      }
    }
    .onAppear { isFocused = true }
  }
}

#Preview {
  NavigationStack {
    TextCaptureView { captured in
      print("committed:", captured.text)
    }
    .navigationTitle("Text")
  }
}
