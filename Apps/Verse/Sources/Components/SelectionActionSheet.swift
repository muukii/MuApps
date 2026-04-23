//
//  SelectionActionSheet.swift
//  YouTubeSubtitle
//
//  Created by Claude on 2025/01/03.
//

import SwiftUI
import UIKit
import ObjectEdge

// MARK: - TextSelection Model

/// Represents a text selection with optional context for explanation
struct TextSelection: Identifiable {
  let id = UUID()
  let text: String
  let context: String

  init(text: String, context: String? = nil) {
    self.text = text
    self.context = context ?? text
  }
}

// MARK: - SelectionActionSheet

/// A bottom sheet that provides actions for selected text.
/// Displays the selected text, action buttons, and explanation section using List-based UI.
struct SelectionActionSheet: View {

  let selection: TextSelection
  let onCopy: () -> Void
  let onDismiss: () -> Void

  @ObjectEdge private var service: ExplanationService = .init()

  // Internal state
  @State private var showVocabulary = false
  @State private var geminiURL: URL?

  var body: some View {
    List {
      selectedTextSection
      actionsSection
      WordExplanationView(
        service: service,
        text: selection.text,
        context: selection.context,
        geminiURL: $geminiURL
      )
    }
    .safeAreaPadding(.top, 20)
    .listStyle(.insetGrouped)
    .presentationDetents([.medium, .large])
    .presentationDragIndicator(.automatic)
    .sheet(isPresented: $showVocabulary) {
      VocabularyEditSheet(mode: .add(initialTerm: selection.text))
    }
    .sheet(item: $geminiURL) { url in
      SafariView(url: url)
        .ignoresSafeArea()
    }
  }

  // MARK: - Sections

  private var selectedTextSection: some View {
    Section {
      Text(selection.text)
        .font(.body)
        .textSelection(.enabled)
    } header: {
      Text("Selected Text")
        .textCase(nil)
    }
  }

  private var actionsSection: some View {
    Section {
      Button {
        showVocabulary = true
      } label: {
        Label("Add to Vocabulary", systemImage: "plus.circle")
      }
    }
  }
}

// MARK: - Preview

#Preview("Default") {
  Text("Preview")
    .sheet(isPresented: .constant(true)) {
      SelectionActionSheet(
        selection: TextSelection(
          text: "serendipity",
          context: "It was pure serendipity that we met at the conference."
        ),
        onCopy: { print("Copy tapped") },
        onDismiss: { print("Dismiss tapped") }
      )
    }
}

#Preview("Long Text") {
  Text("Preview")
    .sheet(isPresented: .constant(true)) {
      SelectionActionSheet(
        selection: TextSelection(
          text: "This is a sample selected text that might be quite long and wrap to multiple lines."
        ),
        onCopy: { print("Copy tapped") },
        onDismiss: { print("Dismiss tapped") }
      )
    }
}
