import SwiftUI

/// Standalone demo harness for `DoodleCanvasView`. Runs on the component's own
/// scheme with a neutral ink color (the app supplies the theme color in
/// production). Exports the drawing and shows a rasterized thumbnail.
public struct DoodleCaptureDemoView: View {

  @State private var lastDrawing: DoodleDrawing?

  private let inkColor: Color = .primary

  public init() {}

  public var body: some View {
    DoodleCanvasView(inkColor: inkColor) { drawing in
      lastDrawing = drawing
    }
    .overlay(alignment: .topTrailing) {
      if let image = lastDrawing?.image(inkColor: inkColor) {
        Image(uiImage: image)
          .resizable()
          .scaledToFit()
          .frame(width: 88, height: 88)
          .background(.white)
          .clipShape(RoundedRectangle(cornerRadius: 12))
          .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.secondary))
          .padding()
      }
    }
    .navigationTitle("Doodle")
    .navigationBarTitleDisplayMode(.inline)
  }
}

#Preview {
  NavigationStack {
    DoodleCaptureDemoView()
  }
}
