import AppUIComponents
import CaptureText
import MuColor
#if os(iOS)
import NextGrowingTextViewSwiftUI
#endif
import SwiftUI

/// Native sheet shell for editing a text card from the composer.
///
/// Text edits bind directly to the draft, so the sheet has no commit or cancel
/// boundary; dismissing it only closes the editor surface.
struct PostDraftTextEditorSheet: View {

  @Bindable var card: CardEditDraft

  var body: some View {
    NavigationStack {
      PostDraftTextEditorContent(text: $card.text)
        .navigationTitle("Text")
        .appInlineNavigationTitle()
    }
  }
}

/// Large-form text input shared by the text sheet and draft detail editor.
struct PostDraftTextEditorContent: View {

  /// Body text for the draft card.
  @Binding var text: String

  @FocusState private var isFocused: Bool

  var body: some View {
    GrowingTextEditor(
      text: $text,
      placeholder: "Write your thoughts...",
      configuration: GrowingTextEditorConfiguration(
        minLines: 4,
        maxLines: 12,
        horizontalPadding: 16,
        verticalPadding: 16
      ),
      font: .system(size: 32, weight: .bold)
    )
    .foregroundStyle(.primary)
    .focused($isFocused)
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .padding(.horizontal, 4)
    .padding(.vertical, 8)
    .onAppear {
      isFocused = true
    }
  }
}

/// Native sheet shell for editing a link card from the composer.
///
/// Link edits bind directly to the draft. The entered URL is normalized when the
/// user submits or dismisses the editor so the saved card stores a canonical
/// URL string.
struct PostDraftLinkEditorSheet: View {

  @Bindable var card: CardEditDraft

  var body: some View {
    NavigationStack {
      PostDraftLinkEditorContent(urlString: $card.text)
        .navigationTitle("Link")
        .appInlineNavigationTitle()
    }
  }
}

/// URL input and live native preview for a link draft.
struct PostDraftLinkEditorContent: View {

  /// Raw URL text for the draft card.
  @Binding var urlString: String

  @FocusState private var isFocused: Bool

  private var linkURL: JournalLinkURL? {
    JournalLinkURL(urlString)
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        TextField("https://example.com", text: $urlString)
          #if os(iOS)
          .keyboardType(.URL)
          .textInputAutocapitalization(.never)
          .textContentType(.URL)
          #endif
          .autocorrectionDisabled()
          .submitLabel(.done)
          .focused($isFocused)
          .font(.title2.weight(.semibold))
          .padding(16)
          .background(
            .appSecondaryContainer,
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
          )
          .foregroundStyle(.appOnSecondaryContainer)
          .onSubmit {
            normalizeURLStringIfPossible()
          }

        if let linkURL {
          JournalLinkPreview(url: linkURL.url)
        } else if urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
          Label("Enter a valid web URL", systemImage: "exclamationmark.triangle")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
        }
      }
      .padding(20)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .background(.background)
    .onAppear { isFocused = true }
    .onDisappear {
      normalizeURLStringIfPossible()
    }
  }

  private func normalizeURLStringIfPossible() {
    guard let linkURL else { return }
    urlString = linkURL.storageString
  }
}
