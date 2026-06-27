import CaptureBauhaus
import SwiftUI

/// Native sheet shell for composing a Bauhaus grid artwork card.
///
/// The grid editor streams every cell edit back to the draft, so dismissal is
/// not a save boundary. Clearing the grid sends `nil` to let the composer restore
/// or remove an automatically-created draft.
struct ThreadDraftBauhausGridSheet: View {

  @Environment(\.dismiss) private var dismiss

  /// Existing draft to edit. `nil` means the caller will resolve a draft when the
  /// first non-empty artwork arrives from the grid editor.
  let card: ThreadDraftCard?

  /// Streams the current artwork after grid changes. `nil` means the grid has
  /// become empty.
  let onChange: @MainActor @Sendable (BauhausGridArtwork?) -> Void

  var body: some View {
    NavigationStack {
      BauhausGridCaptureView(
        initialArtwork: card?.bauhaus ?? .empty,
        onChange: { artwork in
          onChange(artwork.isEmpty ? nil : artwork)
        }
      )
      .navigationTitle("Bauhaus")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") {
            dismiss()
          }
        }
      }
    }
  }
}
