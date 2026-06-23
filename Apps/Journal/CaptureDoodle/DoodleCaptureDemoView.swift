import SwiftUI

/// Standalone demo harness for `DoodleCanvasView`. Exports the drawing and shows
/// it, so the doodle component can be exercised on its own.
public struct DoodleCaptureDemoView: View {

  @State private var lastDrawing: DoodleDrawing?

  public init() {}

  public var body: some View {
    DoodleCanvasView { drawing in
      lastDrawing = drawing
    }
    .overlay(alignment: .topTrailing) {
      if let image = lastDrawing?.image {
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
