import MuColor
import SwiftUI

/// Provides a consistent Cell-width canvas for content renderer previews.
///
/// Concrete sample values remain beside the renderer they exercise. This host
/// owns only the shared app palette, scroll behavior, and readable maximum width.
struct EntryContentPreviewCanvas<Content: View>: View {

  private let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    PrimaryContainer(accentColor: .default) {
      ScrollView {
        content
          .frame(maxWidth: 720)
          .frame(maxWidth: .infinity)
          .padding(16)
      }
      .background(.background)
    }
  }
}
