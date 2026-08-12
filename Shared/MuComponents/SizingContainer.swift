
import SwiftUI

/// for now, it's for vertical only
public struct SizingContainer<Content: View>: View {
  
  public let content: Content
  private let height: Binding<CGFloat>
  
  public init(
    height: Binding<CGFloat>,
    @ViewBuilder content: () -> Content
  ) {
    self.content = content()
    self.height = height
  }
  
  public var body: some View {
    Color.clear
      .frame(height: height.wrappedValue)
      .overlay {          
        content
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self, of: \.size.height) { newHeight in
          height.wrappedValue = newHeight
        }
      }
  }
}
