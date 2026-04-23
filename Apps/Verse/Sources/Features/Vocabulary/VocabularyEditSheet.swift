//
//  VocabularyEditSheet.swift
//  YouTubeSubtitle
//
//  Created by Claude on 2025/12/10.
//

import SwiftUI

struct VocabularyEditSheet: View {
  enum Mode: Identifiable {
    case add(initialTerm: String = "")
    case edit(VocabularyItem)

    var id: String {
      switch self {
      case .add: return "add"
      case .edit(let item): return item.id.uuidString
      }
    }

    var isEditing: Bool {
      if case .edit = self { return true }
      return false
    }

    var initialTerm: String? {
      if case .add(let term) = self, !term.isEmpty {
        return term
      }
      return nil
    }
  }

  let mode: Mode

  @Environment(\.dismiss) private var dismiss
  @Environment(VocabularyService.self) private var vocabularyService

  @State private var foundationModelService = FoundationModelService()

  @State private var term: String = ""
  @State private var meaning: String = ""
  @State private var partOfSpeech: PartOfSpeech? = nil
  @State private var examples: [EditableExample] = []
  @State private var notes: String = ""
  @State private var showDeleteConfirmation: Bool = false

  // Auto-fill state
  @State private var isAutoFilling: Bool = false
  @State private var autoFillError: String?

  /// Editable example for UI state management
  struct EditableExample: Identifiable {
    let id = UUID()
    var originalSentence: String
    var translatedSentence: String
  }

  private var title: String {
    mode.isEditing ? "Edit Term" : "Add Term"
  }

  private var canSave: Bool {
    !term.trimmingCharacters(in: .whitespaces).isEmpty
  }

  var body: some View {
    NavigationStack {
      Form {
        // Term (required) with auto-fill button
        Section {
          HStack {
            TextField("Word or phrase", text: $term)
              .textInputAutocapitalization(.never)

            Button {
              Task {
                await performAutoFill()
              }
            } label: {
              if isAutoFilling {
                ProgressView()
                  .controlSize(.small)
              } else {
                Image(systemName: "sparkles")
              }
            }
            .disabled(term.trimmingCharacters(in: .whitespaces).isEmpty || isAutoFilling)
            .buttonStyle(.borderless)
          }
        } header: {
          Text("Term")
        } footer: {
          if let error = autoFillError {
            Text(error)
              .foregroundStyle(.red)
          } else {
            Text("Tap ✨ to auto-fill fields using AI")
          }
        }

        // Meaning
        Section {
          TextField("Definition or translation", text: $meaning, axis: .vertical)
            .lineLimit(3...6)
        } header: {
          Text("Meaning")
        }

        // Part of Speech
        Section {
          Picker("Part of Speech", selection: $partOfSpeech) {
            Text("Not specified").tag(nil as PartOfSpeech?)
            ForEach(PartOfSpeech.allCases, id: \.self) { pos in
              Text(pos.displayName).tag(pos as PartOfSpeech?)
            }
          }
        } header: {
          Text("Part of Speech")
        }

        // Examples
        Section {
          ForEach($examples) { $example in
            VStack(alignment: .leading, spacing: 8) {
              TextField("Example sentence", text: $example.originalSentence, axis: .vertical)
                .lineLimit(2...4)
              TextField("Translation", text: $example.translatedSentence, axis: .vertical)
                .lineLimit(2...4)
                .foregroundStyle(.secondary)
            }
          }
          .onDelete(perform: deleteExample)

          Button {
            addExample()
          } label: {
            Label("Add Example", systemImage: "plus")
          }
        } header: {
          Text("Examples")
        }

        // Notes
        Section {
          TextField("Your notes", text: $notes, axis: .vertical)
            .lineLimit(2...4)
        } header: {
          Text("Notes")
        }

        // Delete (edit mode only)
        if case .edit(let item) = mode {
          Section {
            Button(role: .destructive) {
              showDeleteConfirmation = true
            } label: {
              HStack {
                Spacer()
                Text("Delete Term")
                Spacer()
              }
            }
          }
          .confirmationDialog(
            "Delete \"\(item.term)\"?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
          ) {
            Button("Delete", role: .destructive) {
              try? vocabularyService.deleteItem(item)
              dismiss()
            }
          } message: {
            Text("This action cannot be undone.")
          }
        }
      }
      .navigationTitle(title)
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
      .onAppear {
        loadInitialValues()
      }
    }
    .presentationDetents([.medium, .large])
  }

  // MARK: - Actions

  private func loadInitialValues() {
    switch mode {
    case .add(let initialTerm):
      if !initialTerm.isEmpty {
        term = initialTerm
      }

    case .edit(let item):
      term = item.term
      meaning = item.meaning ?? ""
      partOfSpeech = item.partOfSpeech
      notes = item.notes ?? ""

      // Load examples
      examples = item.sortedExamples.map { example in
        EditableExample(
          originalSentence: example.originalSentence,
          translatedSentence: example.translatedSentence
        )
      }
    }
  }

  private func save() {
    let trimmedTerm = term.trimmingCharacters(in: .whitespaces)
    guard !trimmedTerm.isEmpty else { return }

    let trimmedMeaning = meaning.isEmpty ? nil : meaning
    let trimmedNotes = notes.isEmpty ? nil : notes

    // Convert EditableExample to ExampleInput
    let exampleInputs = examples
      .filter { !$0.originalSentence.trimmingCharacters(in: .whitespaces).isEmpty }
      .map { VocabularyService.ExampleInput(
        originalSentence: $0.originalSentence,
        translatedSentence: $0.translatedSentence
      )}

    switch mode {
    case .add:
      try? vocabularyService.addItem(
        term: trimmedTerm,
        meaning: trimmedMeaning,
        notes: trimmedNotes,
        partOfSpeech: partOfSpeech,
        examples: exampleInputs,
        duplicateHandling: .allowDuplicate
      )

    case .edit(let item):
      try? vocabularyService.updateItem(
        item,
        term: trimmedTerm,
        meaning: trimmedMeaning,
        notes: trimmedNotes,
        partOfSpeech: partOfSpeech,
        examples: exampleInputs
      )
    }

    dismiss()
  }

  private func performAutoFill() async {
    let trimmedTerm = term.trimmingCharacters(in: .whitespaces)
    guard !trimmedTerm.isEmpty else { return }

    isAutoFilling = true
    autoFillError = nil

    do {
      let response = try await foundationModelService.generateVocabularyAutoFill(
        term: trimmedTerm,
        context: nil
      )

      // Only fill empty fields to preserve user input
      if meaning.isEmpty && !response.meaning.isEmpty {
        meaning = response.meaning
      }
      if partOfSpeech == nil {
        partOfSpeech = PartOfSpeech(rawValue: response.partOfSpeech.lowercased())
      }
      if examples.isEmpty && !response.examples.isEmpty {
        examples = response.examples.map { example in
          EditableExample(
            originalSentence: example.originalSentence,
            translatedSentence: example.translatedSentence
          )
        }
      }
      if notes.isEmpty && !response.notes.isEmpty {
        notes = response.notes
      }
    } catch {
      autoFillError = error.localizedDescription
    }

    isAutoFilling = false
  }

  // MARK: - Example Management

  private func addExample() {
    examples.append(EditableExample(originalSentence: "", translatedSentence: ""))
  }

  private func deleteExample(at offsets: IndexSet) {
    examples.remove(atOffsets: offsets)
  }
}

// MARK: - Preview

#Preview("Add") {
  VocabularyEditSheet(mode: .add())
}
