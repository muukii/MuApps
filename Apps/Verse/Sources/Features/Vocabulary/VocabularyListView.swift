//
//  VocabularyListView.swift
//  YouTubeSubtitle
//
//  Created by Claude on 2025/12/10.
//

import SwiftUI
import SwiftData

struct VocabularyListView: View {
  @Environment(VocabularyService.self) private var vocabularyService
  @Query(sort: \VocabularyItem.createdAt, order: .reverse) private var items: [VocabularyItem]

  @State private var searchText: String = ""
  @State private var showAddSheet: Bool = false
  @State private var selectedItem: VocabularyItem?

  private var filteredItems: [VocabularyItem] {
    guard !searchText.isEmpty else { return items }
    let lowercaseQuery = searchText.lowercased()
    return items.filter { item in
      item.term.lowercased().contains(lowercaseQuery) ||
      (item.meaning?.lowercased().contains(lowercaseQuery) ?? false)
    }
  }

  var body: some View {
    NavigationStack {
      Group {
        if items.isEmpty {
          emptyStateView
        } else {
          listView
        }
      }
      .navigationTitle("Vocabulary")
      .searchable(text: $searchText, prompt: "Search terms")
      .toolbar {
        ToolbarItem(placement: .primaryAction) {
          Button {
            showAddSheet = true
          } label: {
            Label("Add", systemImage: "plus")
          }
        }
      }
      .sheet(isPresented: $showAddSheet) {
        VocabularyEditSheet(mode: .add())
      }
      .sheet(item: $selectedItem) { item in
        VocabularyEditSheet(mode: .edit(item))
      }
    }
  }

  // MARK: - Empty State

  private var emptyStateView: some View {
    ContentUnavailableView {
      Label("No Vocabulary", systemImage: "text.book.closed")
    } description: {
      Text("Save words and phrases from subtitles\nto build your vocabulary.")
    } actions: {
      Button {
        showAddSheet = true
      } label: {
        Label("Add First Term", systemImage: "plus")
      }
      .buttonStyle(.bordered)
    }
  }

  // MARK: - List View

  private var listView: some View {
    List {
      ForEach(filteredItems) { item in
        VocabularyCell(item: item)
          .contentShape(Rectangle())
          .onTapGesture {
            selectedItem = item
          }
      }
      .onDelete(perform: deleteItems)
    }
    .listStyle(.inset)
    .overlay {
      if !searchText.isEmpty && filteredItems.isEmpty {
        ContentUnavailableView.search(text: searchText)
      }
    }
  }

  // MARK: - Actions

  private func deleteItems(at offsets: IndexSet) {
    let itemsToDelete = offsets.map { filteredItems[$0] }
    try? vocabularyService.deleteItems(itemsToDelete)
  }
}

// MARK: - Vocabulary Cell

struct VocabularyCell: View {
  let item: VocabularyItem

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      // Term
      Text(item.term)
        .font(.headline)

      // Meaning
      if let meaning = item.meaning, !meaning.isEmpty {
        Text(meaning)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }

      // Part of Speech
      if let partOfSpeech = item.partOfSpeech {
        Text(partOfSpeech.displayName)
          .font(.caption)
          .foregroundStyle(.tertiary)
      }

      // Footer: Date and Learning State
      HStack {
        Text(formatDate(item.createdAt))
          .font(.caption2)
          .foregroundStyle(.tertiary)

        Spacer()

        LearningStateBadge(state: item.learningState)
      }
    }
    .padding(.vertical, 4)
  }

  private func formatDate(_ date: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: date, relativeTo: Date())
  }
}

// MARK: - Learning State Badge

struct LearningStateBadge: View {
  let state: VocabularyItem.LearningState

  var body: some View {
    Text(state.displayName)
      .font(.caption2)
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(state.color.opacity(0.15))
      .foregroundStyle(state.color)
      .clipShape(Capsule())
  }
}

extension VocabularyItem.LearningState {
  var displayName: String {
    switch self {
    case .new: return "New"
    case .learning: return "Learning"
    case .reviewing: return "Reviewing"
    case .mastered: return "Mastered"
    }
  }

  var color: Color {
    switch self {
    case .new: return .blue
    case .learning: return .orange
    case .reviewing: return .purple
    case .mastered: return .green
    }
  }
}

// MARK: - Preview

#Preview {
  VocabularyListView()
}
