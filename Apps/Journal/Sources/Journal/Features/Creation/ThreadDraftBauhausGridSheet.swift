import CaptureBauhaus
import SwiftUI

/// Native sheet shell for composing a Bauhaus grid artwork card.
///
/// The grid editor streams every cell edit back to the draft, so dismissal is
/// not a save boundary. Clearing the grid sends `nil` to let the composer
/// restore or remove an automatically-created draft.
struct ThreadDraftBauhausGridSheet: View {

  /// Existing draft to edit. `nil` means the caller will resolve a draft when the
  /// first non-empty artwork arrives from the grid editor.
  let card: ThreadDraftCard?

  /// Streams the current document after grid changes. `nil` means the grid has
  /// become empty and should not leave a savable draft behind.
  let onChange: @MainActor @Sendable (BauhausGridDocument?) -> Void

  var body: some View {
    NavigationStack {
      BauhausGridCaptureView(
        initialDocument: card?.bauhaus ?? .empty,
        onChange: { document in
          onChange(document.artwork.isEmpty ? nil : document)
        }
      )
      .navigationTitle("Bauhaus")
      .navigationBarTitleDisplayMode(.inline)
    }
  }
}
