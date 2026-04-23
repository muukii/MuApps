//
//  CreatePlaylistSheet.swift
//  YouTubeSubtitle
//

import SwiftUI

struct CreatePlaylistSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(VideoItemService.self) private var historyService

  @State private var name: String = ""
  @FocusState private var isNameFocused: Bool

  private var canSave: Bool {
    !name.trimmingCharacters(in: .whitespaces).isEmpty
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField("Playlist name", text: $name)
            .focused($isNameFocused)
        } footer: {
          Text("Give your playlist a descriptive name.")
        }
      }
      .navigationTitle("New Playlist")
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
          Button("Create") {
            createPlaylist()
          }
          .disabled(!canSave)
        }
      }
      .onAppear {
        isNameFocused = true
      }
    }
  }

  private func createPlaylist() {
    let trimmedName = name.trimmingCharacters(in: .whitespaces)
    guard !trimmedName.isEmpty else { return }

    try? historyService.createPlaylist(name: trimmedName)
    dismiss()
  }
}

// MARK: - Preview

#Preview {
  CreatePlaylistSheet()
}
