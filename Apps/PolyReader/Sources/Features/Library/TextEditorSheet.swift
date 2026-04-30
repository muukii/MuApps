import SwiftData
import SwiftUI

struct TextEditorSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.modelContext) private var modelContext

  @State private var title = ""
  @State private var textBody = ""

  private var canSave: Bool {
    !textBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField("Optional title", text: $title)
        } header: {
          Text("Title")
        }

        Section {
          TextEditor(text: $textBody)
            .frame(minHeight: 260)
            .textInputAutocapitalization(.sentences)
        } header: {
          Text("Text")
        } footer: {
          Text("Paste or type the text you want to read sentence by sentence.")
        }
      }
      .navigationTitle("Add Text")
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            dismiss()
          }
        }

        ToolbarItem(placement: .confirmationAction) {
          Button("Save") {
            save()
          }
          .disabled(!canSave)
        }
      }
    }
    .presentationDetents([.medium, .large])
  }

  private func save() {
    let trimmedBody = textBody.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedBody.isEmpty else { return }

    let readingText = ReadingText(
      title: resolvedTitle(for: trimmedBody),
      body: trimmedBody
    )

    modelContext.insert(readingText)
    try? modelContext.save()
    dismiss()
  }

  private func resolvedTitle(for body: String) -> String {
    let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedTitle.isEmpty {
      return trimmedTitle
    }

    let firstLine = body
      .components(separatedBy: .newlines)
      .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?
      .trimmingCharacters(in: .whitespacesAndNewlines)

    guard let firstLine, !firstLine.isEmpty else {
      return "Untitled Text"
    }

    return String(firstLine.prefix(60))
  }
}
