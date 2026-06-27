import CaptureDoodle
import MuColor
import SwiftUI

/// Dev-gallery host for the doodle component. Supplies the theme ink color
/// (`onPrimaryContainer`) and surface, and offers an in-place theme switch so the
/// theme-reactive re-tinting of already-drawn strokes is visible without leaving
/// the screen — the whole point of storing doodles as colorless vectors.
struct DoodleCaptureView: View {

  @Environment(\.appPalette) private var palette
  @AppStorage(JournalDefaults.themeID) private var themeID: String = Theme.default.id
  @State private var lastDrawing: DoodleDrawing?

  var body: some View {
    DoodleCanvasView(inkColor: palette.onPrimaryContainer) { drawing in
      lastDrawing = drawing
    }
    .background(palette.primaryContainer)
    .overlay(alignment: .topTrailing) {
      if let image = lastDrawing?.image(inkColor: palette.onPrimaryContainer) {
        Image(uiImage: image)
          .resizable()
          .scaledToFit()
          .frame(width: 88, height: 88)
          .background(palette.primaryContainer)
          .clipShape(RoundedRectangle(cornerRadius: 12))
          .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(palette.outline))
          .padding()
      }
    }
    .navigationTitle("Doodle")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Menu {
          Picker("Theme", selection: $themeID) {
            ForEach(Theme.all) { theme in
              Text(theme.name).tag(theme.id)
            }
          }
        } label: {
          Image(systemName: "paintpalette")
        }
      }
    }
  }
}
