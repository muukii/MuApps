import SwiftUI

/// Native sheet shell for editing a text card from the composer.
///
/// Text edits bind directly to the draft, so the sheet has no commit or cancel
/// boundary; dismissing it only closes the editor surface.
struct ThreadDraftTextEditorSheet: View {

  @Bindable var card: ThreadDraftCard

  var body: some View {
    NavigationStack {
      ThreadDraftTextEditorContent(text: $card.text)
        .navigationTitle("Text")
        .navigationBarTitleDisplayMode(.inline)
    }
  }
}

/// Large-form text input shared by the text sheet and draft detail editor.
struct ThreadDraftTextEditorContent: View {

  /// Body text for the draft card.
  @Binding var text: String

  @FocusState private var isFocused: Bool

  var body: some View {
    ZStack(alignment: .topLeading) {
      if text.isEmpty {
        Text("Write your thoughts...")
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
    .font(.system(size: 32, weight: .bold))
    .onAppear { isFocused = true }
  }
}
