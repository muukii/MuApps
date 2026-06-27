import SwiftUI

/// Standalone demo harness for the gradient blob painter.
public struct BlobCaptureDemoView: View {

  @State private var lastPainting: BlobPainting?

  public init() {}

  public var body: some View {
    BlobPaintCanvasView { painting in
      lastPainting = painting
    }
    .overlay(alignment: .topTrailing) {
      if let image = lastPainting?.image() {
        Image(uiImage: image)
          .resizable()
          .scaledToFit()
          .frame(width: 88, height: 88)
          .background(Color(red: 0.94, green: 0.93, blue: 0.90))
          .clipShape(RoundedRectangle(cornerRadius: 12))
          .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.secondary))
          .padding()
      }
    }
    .navigationTitle("Blob Paint")
    .navigationBarTitleDisplayMode(.inline)
  }
}

#Preview {
  NavigationStack {
    BlobCaptureDemoView()
  }
}
