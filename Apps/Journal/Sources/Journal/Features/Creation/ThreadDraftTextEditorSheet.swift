import SwiftUI

/// Native sheet shell for editing a text card from the composer.
///
/// Text drafts are created before presentation because typing is the capture
/// act itself. Dismissing this sheet leaves the draft in place, matching the
/// existing composer behavior for an empty text placeholder.
struct ThreadDraftTextEditorSheet: View {

  @Environment(\.dismiss) private var dismiss

  /// Draft whose body text and location metadata are edited by the sheet.
  @Bindable var card: ThreadDraftCard

  /// Whether the composer is currently saving and should block metadata edits.
  let isSaving: Bool

  /// Toggles the card's attached coordinate through the Creation-level location
  /// permission bridge.
  let onToggleLocation: @MainActor @Sendable () -> Void

  var body: some View {
    NavigationStack {
      ThreadDraftTextEditorContent(text: $card.text)
        .navigationTitle("Text")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .confirmationAction) {
            Button("Done") {
              dismiss()
            }
          }

          ToolbarItem(placement: .navigationBarLeading) {
            Button(action: onToggleLocation) {
              Image(systemName: card.location != nil ? "location.fill" : "location")
            }
            .disabled(isSaving)
            .accessibilityLabel(card.location != nil ? "Location attached" : "Attach location")
          }
        }
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
