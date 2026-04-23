//
//  TranscriptionSessionHistoryView.swift
//  YouTubeSubtitle
//
//  Created by Claude on 2025/12/14.
//

import SwiftData
import SwiftUI

/// View displaying the history of transcription sessions
struct TranscriptionSessionHistoryView: View {
  @Environment(\.modelContext) private var modelContext
  @Environment(\.dismiss) private var dismiss
  @Query(sort: \TranscriptionSession.createdAt, order: .reverse)
  private var sessions: [TranscriptionSession]

  @State private var selectedSession: TranscriptionSession?
  @State private var showDeleteConfirmation = false
  @State private var sessionToDelete: TranscriptionSession?

  var body: some View {
    NavigationStack {
      Group {
        if sessions.isEmpty {
          emptyStateView
        } else {
          sessionListView
        }
      }
      .navigationTitle("Session History")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") {
            dismiss()
          }
        }
      }
      .sheet(item: $selectedSession) { session in
        TranscriptionSessionDetailView(session: session)
      }
      .confirmationDialog(
        "Delete Session",
        isPresented: $showDeleteConfirmation,
        presenting: sessionToDelete
      ) { session in
        Button("Delete", role: .destructive) {
          deleteSession(session)
        }
      } message: { session in
        Text("Are you sure you want to delete this session? This action cannot be undone.")
      }
    }
  }

  // MARK: - Empty State

  private var emptyStateView: some View {
    ContentUnavailableView(
      "No Sessions",
      systemImage: "waveform.slash",
      description: Text("Start recording to create transcription sessions")
    )
  }

  // MARK: - Session List

  private var sessionListView: some View {
    List {
      ForEach(sessions) { session in
        SessionRowView(session: session)
          .contentShape(Rectangle())
          .onTapGesture {
            selectedSession = session
          }
          .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
              sessionToDelete = session
              showDeleteConfirmation = true
            } label: {
              Label("Delete", systemImage: "trash")
            }
          }
      }
    }
    .listStyle(.plain)
  }

  // MARK: - Actions

  private func deleteSession(_ session: TranscriptionSession) {
    let service = TranscriptionSessionService(modelContext: modelContext)
    do {
      try service.deleteSession(session)
    } catch {
      print("Failed to delete session: \(error)")
    }
    sessionToDelete = nil
  }
}

// MARK: - Session Row View

private struct SessionRowView: View {
  let session: TranscriptionSession

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      // Title and date
      HStack {
        Text(session.displayTitle)
          .font(.headline)
          .lineLimit(1)

        Spacer()

        Text(formattedDate)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      // Preview text
      if !session.fullText.isEmpty {
        Text(session.fullText)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }

      // Stats
      HStack(spacing: 16) {
        Label("\(session.entryCount)", systemImage: "text.bubble")
          .font(.caption)
          .foregroundStyle(.tertiary)

        Label(formattedDuration, systemImage: "clock")
          .font(.caption)
          .foregroundStyle(.tertiary)
      }
    }
    .padding(.vertical, 4)
  }

  private var formattedDate: String {
    let formatter = DateFormatter()
    formatter.dateStyle = .short
    formatter.timeStyle = .short
    return formatter.string(from: session.createdAt)
  }

  private var formattedDuration: String {
    let minutes = Int(session.duration) / 60
    let seconds = Int(session.duration) % 60
    return String(format: "%d:%02d", minutes, seconds)
  }
}

// MARK: - Session Detail View

struct TranscriptionSessionDetailView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.modelContext) private var modelContext

  let session: TranscriptionSession
  @State private var editedTitle: String = ""
  @State private var isEditing = false
  @State private var selectionForActionSheet: TextSelection?

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          // Session info
          sessionInfoSection

          Divider()

          // Entries
          entriesSection
        }
        .padding()
      }
      .navigationTitle(isEditing ? "Edit Title" : "Session Detail")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") {
            dismiss()
          }
        }

        ToolbarItem(placement: .primaryAction) {
          ShareLink(item: exportText) {
            Image(systemName: "square.and.arrow.up")
          }
        }
      }
      .onAppear {
        editedTitle = session.title ?? ""
      }
      .sheet(item: $selectionForActionSheet) { selection in
        SelectionActionSheet(
          selection: selection,
          onCopy: { selectionForActionSheet = nil },
          onDismiss: { selectionForActionSheet = nil }
        )
      }
    }
  }

  // MARK: - Session Info Section

  private var sessionInfoSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      // Editable title
      HStack {
        if isEditing {
          TextField("Session Title", text: $editedTitle)
            .textFieldStyle(.roundedBorder)
            .onSubmit {
              saveTitle()
            }

          Button("Save") {
            saveTitle()
          }
          .buttonStyle(.borderedProminent)
        } else {
          Text(session.displayTitle)
            .font(.title2)
            .fontWeight(.bold)

          Spacer()

          Button {
            isEditing = true
          } label: {
            Image(systemName: "pencil")
          }
          .buttonStyle(.bordered)
        }
      }

      // Date and duration
      HStack(spacing: 16) {
        Label(formattedDate, systemImage: "calendar")
        Label(formattedDuration, systemImage: "clock")
        Label("\(session.entryCount) segments", systemImage: "text.bubble")
      }
      .font(.subheadline)
      .foregroundStyle(.secondary)
    }
  }

  // MARK: - Entries Section

  private var entriesSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Transcription")
        .font(.headline)

      let sortedEntries = session.entries.sorted { $0.timestamp < $1.timestamp }
      ForEach(sortedEntries) { entry in
        TranscriptionBubbleView(
          item: entry,
          onExplain: { text in
            // Redirect to SelectionActionSheet (which now embeds WordExplanationView)
            selectionForActionSheet = TextSelection(text: text)
          },
          onShowActions: { text in
            selectionForActionSheet = TextSelection(text: text)
          }
        )
      }
    }
  }

  // MARK: - Helpers

  private var formattedDate: String {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter.string(from: session.createdAt)
  }

  private var formattedDuration: String {
    let minutes = Int(session.duration) / 60
    let seconds = Int(session.duration) % 60
    return String(format: "%d:%02d", minutes, seconds)
  }

  private var exportText: String {
    let sortedEntries = session.entries.sorted { $0.timestamp < $1.timestamp }
    return sortedEntries.map { entry in
      "[\(entry.formattedTime)] \(entry.text)"
    }.joined(separator: "\n\n")
  }

  private func saveTitle() {
    let service = TranscriptionSessionService(modelContext: modelContext)
    do {
      try service.updateTitle(session, title: editedTitle.isEmpty ? nil : editedTitle)
    } catch {
      print("Failed to save title: \(error)")
    }
    isEditing = false
  }
}

// MARK: - Preview

#Preview {
  TranscriptionSessionHistoryView()
    .modelContainer(for: [TranscriptionSession.self, TranscriptionEntry.self])
}
