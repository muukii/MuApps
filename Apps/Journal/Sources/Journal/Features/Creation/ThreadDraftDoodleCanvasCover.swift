import CaptureDoodle
import MuColor
import SwiftUI

/// Dedicated full-screen shell for drawing a doodle card from the composer.
///
/// Doodle editing benefits from the whole display: the canvas keeps the journal
/// card aspect ratio, while the surrounding full-screen presentation gives the
/// user's finger room to draw without fighting a sheet detent.
struct ThreadDraftDoodleCanvasCover: View {

  @Environment(\.dismiss) private var dismiss

  /// Existing draft to edit. `nil` means the caller will resolve a draft when the
  /// first non-empty drawing arrives from the canvas.
  let card: ThreadDraftCard?

  /// Streams the current drawing after committed canvas changes. `nil` means the
  /// canvas has become empty.
  let onChange: @MainActor @Sendable (DoodleDrawing?) -> Void

  var body: some View {
    NavigationStack {
      ThreadDraftDoodleCanvasContent(card: card, onChange: onChange)
        .navigationTitle("Doodle")
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

/// Native sheet shell for drawing a quick doodle card from the composer.
///
/// The sheet keeps quick creation in the same presentation family as Text,
/// Photo, and Voice while still reusing the full canvas content.
struct ThreadDraftDoodleCanvasSheet: View {

  /// Existing draft to edit. `nil` means the caller will resolve a draft when the
  /// first non-empty drawing arrives from the canvas.
  let card: ThreadDraftCard?

  /// Streams the current drawing after committed canvas changes. `nil` means the
  /// canvas has become empty.
  let onChange: @MainActor @Sendable (DoodleDrawing?) -> Void

  var body: some View {
    NavigationStack {
      ThreadDraftDoodleCanvasContent(card: card, onChange: onChange)
        .navigationTitle("Doodle")
        .navigationBarTitleDisplayMode(.inline)
    }
  }
}

/// Doodle canvas content shared by the dedicated cover and the fallback draft
/// detail editor.
struct ThreadDraftDoodleCanvasContent: View {

  @Environment(\.appPalette) private var palette

  /// Existing draft whose drawing should be loaded into the canvas.
  let card: ThreadDraftCard?

  /// Streams the current drawing after committed canvas changes.
  let onChange: @MainActor @Sendable (DoodleDrawing?) -> Void

  var body: some View {
    DoodleCanvasView(
      inkColor: palette.tint,
      initialDrawing: card?.doodle,
      onChange: onChange
    )
  }
}
