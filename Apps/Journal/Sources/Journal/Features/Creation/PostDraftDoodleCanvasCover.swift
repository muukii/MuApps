import CaptureDoodle
import MuColor
import SwiftUI

/// Dedicated full-screen shell for drawing Doodle content from the composer.
///
/// Doodle editing benefits from the whole display: the canvas keeps the journal
/// authored Doodle ratio, while the surrounding full-screen presentation gives the
/// user's finger room to draw without fighting a sheet detent.
struct PostDraftDoodleCanvasCover: View {

  @Environment(\.dismiss) private var dismiss

  /// Existing draft to edit. `nil` means the caller will resolve a draft when the
  /// first non-empty drawing arrives from the canvas.
  let card: CardEditDraft?

  /// Streams the current drawing after committed canvas changes. `nil` means the
  /// canvas has become empty.
  let onChange: @MainActor @Sendable (DoodleDrawing?) -> Void

  var body: some View {
    NavigationStack {
      PostDraftDoodleCanvasContent(card: card, onChange: onChange)
        .navigationTitle("Doodle")
        .appInlineNavigationTitle()
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

/// Native sheet shell for drawing quick Doodle content from the composer.
///
/// The sheet keeps quick creation in the same presentation family as Text,
/// Photo, and Voice while still reusing the full canvas content.
struct PostDraftDoodleCanvasSheet: View {

  /// Existing draft to edit. `nil` means the caller will resolve a draft when the
  /// first non-empty drawing arrives from the canvas.
  let card: CardEditDraft?

  /// Streams the current drawing after committed canvas changes. `nil` means the
  /// canvas has become empty.
  let onChange: @MainActor @Sendable (DoodleDrawing?) -> Void

  var body: some View {
    NavigationStack {
      PostDraftDoodleCanvasContent(card: card, onChange: onChange)
        .navigationTitle("Doodle")
        .appInlineNavigationTitle()
    }
  }
}

/// Doodle canvas content shared by the dedicated cover and the fallback draft
/// detail editor.
struct PostDraftDoodleCanvasContent: View {

  @Environment(\.appPalette) private var palette

  /// Existing draft whose drawing should be loaded into the canvas.
  let card: CardEditDraft?

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
