import SwiftUI
internal import SwiftUIScrollViewInteroperableDragGesture
import SwiftUISnapDraggingModifier

public struct SwipeCell<Content: View>: View {

  private let content: Content

  @State var offset: CGSize = .zero
  private let onTrigger: () -> Void
  
  private var isTriggering: Bool {
    offset.width < -44
  }

  public init(
    @ViewBuilder content: () -> Content,
    onTrigger: @escaping () -> Void
  ) {
    self.content = content()
    self.onTrigger = onTrigger
  }

  public var body: some View {
    content
      .modifier(
        SnapDraggingModifier(
          gestureMode: .scrollViewInteroperable(
            .init(
              ignoresScrollView: true,
              targetEdges: [],
              sticksToEdges: false
            )
          ),
          offset: $offset,
          axis: [.horizontal],
          horizontalBoundary: .init(
            min: -50,
            max: 0,
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
        alignment: .trailing,
        content: { 
          Circle()
            .foregroundStyle(.quinary)
            .overlay {
              Image(systemName: "arrowshape.turn.up.backward.fill")
                .foregroundStyle(.primary)
            }
            .frame(width: 44, height: 44)
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
            })
        }
      )
      .sensoryFeedback(trigger: isTriggering, { oldValue, newValue in
        if newValue, oldValue == false {
          return .impact
        } else {
          return nil
        }
      })
     
  }

}

#Preview {
  SwipeCell {
    RoundedRectangle(cornerRadius: 10)
      .frame(height: 100)
  } onTrigger: {
    print("trigger")
  }
}
