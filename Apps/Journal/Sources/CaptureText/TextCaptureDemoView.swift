import SwiftUI

/// Standalone demo harness for `TextCaptureView`, used by the dev gallery so the
/// component can be exercised on its own.
public struct TextCaptureDemoView: View {

  @State private var lastSaved: CapturedText?

  public init() {}

  public var body: some View {
    VStack(spacing: 0) {
      TextCaptureView { captured in
        lastSaved = captured
      }

      if let lastSaved {
        Divider()
        VStack(alignment: .leading, spacing: 4) {
          Text("Last saved")
            .font(.caption)
            .foregroundStyle(.secondary)
          Text(lastSaved.text)
            .font(.callout)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
      }
    }
    .background(.background)
    .navigationTitle("Text")
    .navigationBarTitleDisplayMode(.inline)
  }
}

#Preview {
  NavigationStack {
    TextCaptureDemoView()
  }
}
