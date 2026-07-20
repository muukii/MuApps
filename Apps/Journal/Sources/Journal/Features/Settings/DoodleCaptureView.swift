import CaptureDoodle
import MuColor
import SwiftUI

/// Dev-gallery host for the doodle component. Supplies neutral ink and surface
/// colors while allowing the app accent to be inspected in place.
struct DoodleCaptureView: View {

  @Environment(\.appPalette) private var palette
  @AppStorage(JournalDefaults.accentColorID)
  private var accentColorID: String = AccentColor.default.id
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
    .appInlineNavigationTitle()
    .toolbar {
      ToolbarItem(placement: .appTrailingAction) {
        Menu {
          Picker("Accent Color", selection: $accentColorID) {
            ForEach(AccentColor.all) { accentColor in
              Text(accentColor.name).tag(accentColor.id)
            }
          }
        } label: {
          Image(systemName: "paintpalette")
        }
      }
    }
  }
}
