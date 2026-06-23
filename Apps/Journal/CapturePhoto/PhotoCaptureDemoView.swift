import SwiftUI

/// Standalone demo harness for `PhotoCaptureView`. Shows the most recent capture
/// so the camera component can be exercised on its own (run on a real device —
/// the Simulator has no camera).
public struct PhotoCaptureDemoView: View {

  @State private var lastPhoto: CapturedPhoto?

  public init() {}

  public var body: some View {
    PhotoCaptureView { photo in
      lastPhoto = photo
    }
    .overlay(alignment: .bottomLeading) {
      if let image = lastPhoto?.image {
        Image(uiImage: image)
          .resizable()
          .scaledToFill()
          .frame(width: 72, height: 72)
          .clipShape(RoundedRectangle(cornerRadius: 12))
          .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white, lineWidth: 2))
          .padding()
      }
    }
    .navigationTitle("Photo")
    .navigationBarTitleDisplayMode(.inline)
    .toolbarColorScheme(.dark, for: .navigationBar)
  }
}

#Preview {
  NavigationStack {
    PhotoCaptureDemoView()
  }
}
