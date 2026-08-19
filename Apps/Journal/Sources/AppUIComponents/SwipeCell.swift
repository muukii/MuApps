import SwiftUI

#if os(iOS)
  import SwiftUISnapDraggingModifier
#endif

/// A content cell that exposes a snap-to-trigger swipe action on iPhone and iPad.
///
/// Native macOS renders `Content` unchanged and installs no swipe interaction.
public struct SwipeCell<Content: View, Info: View>: View {

  private let content: Content
  private let info: Info

  #if os(iOS)
    @State private var infoWidth: CGFloat = 0
    @State private var offset: CGSize = .zero
  #endif
  private let onTrigger: () -> Void

  #if os(iOS)
    private var isTriggering: Bool {
      offset.width > 44
    }
  #endif

  public init(
    @ViewBuilder content: () -> Content,
    @ViewBuilder info: () -> Info,
    onTrigger: @escaping () -> Void
  ) {
    self.content = content()
    self.info = info()
    self.onTrigger = onTrigger
  }

  public var body: some View {
    #if os(iOS)
      content
        .modifier(
          SnapDraggingModifier(
            gestureMode: .directional,
            offset: $offset,
            axis: [.horizontal],
            horizontalBoundary: .init(
              min: -infoWidth,
              max: 50,
              bandLength: 50
            ),
            handler: .init(
              onEndDragging: { velocity, offset, contentSize in

                if self.isTriggering {
                  onTrigger()
                }
                return .zero

              },
              onCompleteAnimation: {

              }
            )
          )
        )
        .background(
          alignment: .leading,
          content: {
            Circle()
              .foregroundStyle(.quinary)
              .overlay {
                Image(systemName: "arrowshape.turn.up.backward.fill")
                  .resizable()
                  .aspectRatio(contentMode: .fit)
                  .foregroundStyle(.primary)
                  .frame(width: 14)
              }
              .frame(width: 36, height: 36)
              .padding(10)
              .animation(
                .smooth,
                body: {
                  $0
                    .scaleEffect(
                      isTriggering ? 1 : 0.1
                    )
                    .opacity(isTriggering ? 1 : 0)
                    .blur(radius: isTriggering ? 0 : 10)
                }
              )
          }
        )
        .background(alignment: .trailing) {
          info
            .onGeometryChange(
              for: CGFloat.self,
              of: \.size.width,
              action: { newValue in
                infoWidth = newValue
              }
            )
        }
        .sensoryFeedback(
          trigger: isTriggering,
          { oldValue, newValue in
            if newValue, oldValue == false {
              return .impact
            } else {
              return nil
            }
          }
        )
    #else
      content
    #endif

  }

}

#Preview {
  SwipeCell {
    RoundedRectangle(cornerRadius: 10)
      .frame(height: 100)
  } info: {
    Text("Hello")
  } onTrigger: {
    print("trigger")
  }
}
