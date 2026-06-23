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
/// `onCommit`; owns no persistence and knows nothing about JournalEntry.
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
    ZStack(alignment: .topLeading) {
      Group {
        if text.isEmpty {
          Text(placeholder)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
            .allowsHitTesting(false)
        }

        TextEditor(text: $text)
          .foregroundStyle(.primary)
          .focused($isFocused)
          .scrollContentBackground(.hidden)
          .padding(16)
      }
      .font(.system(size: 32))
      .fontWeight(.bold)
    }
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
    .background(.background)
    .onAppear { isFocused = true }
  }
}

struct FloatingCardContainer: View {

  @State private var isAnimated: Bool = false

  var body: some View {
    ZStack {
      Text("Hello")
        .font(.system(size: 32))
        .fontWeight(.bold)
    }
    .padding(16)
    .background {
      RoundedRectangle(cornerRadius: 16)
        .fill(.background)
    }
    .animation(
      .spring(
        Spring(
          settlingDuration: 4.1,
          dampingRatio: 1,
          epsilon: 0.1
        )
      ).repeatForever(),
      body: { content in
        content.rotationEffect(.degrees(isAnimated ? -5 : 5))
      }
    )
    .animation(
      .spring(
        Spring(
          settlingDuration: 2.3,
          dampingRatio: 0.8,
          epsilon: 0.2
        )
      ).repeatForever(),
      body: { content in
        content
          .offset(y: isAnimated ? -8 : 8)
          .scaleEffect(isAnimated ? 1.12 : 1)
      }
    )
    .backgroundStyle(.red)
    .onAppear {
      isAnimated = true
    }
  }
}

#Preview {
  FloatingCardContainer()
}

#Preview {
  NavigationStack {
    TextCaptureView { captured in
      print("committed:", captured.text)
    }
    .navigationTitle("Text")
  }
}
