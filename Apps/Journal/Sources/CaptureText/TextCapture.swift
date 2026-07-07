import GrowingTextEditor
import SwiftUI

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
