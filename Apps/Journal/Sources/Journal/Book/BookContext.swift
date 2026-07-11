import SwiftUI
#if canImport(SwiftUISnapDraggingModifier)
import SwiftUISnapDraggingModifier
#endif
public import Combine

#Preview {
  BookMatchedShape()
}

struct BookMatchedShape: View {
  var body: some View {
    __Stack()
  }

  private final class Controller: ObservableObject {

    @Published var details: [AnyView] = []

  }

  private struct Link: View {

    let namespace: Namespace.ID
    let isActive: Bool

    var body: some View {
      // subject
      let item = ContainerView {

        ZStack {
          VStack(alignment: .leading) {
            HStack(spacing: 12) {
              Circle()
                .frame(
                  width: 40,
                  height: 40,
                  alignment: .center
                )
            }
            .padding(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
          }
//          .blur(radius: isActive ? 30 : 0)
        }

      }

      .matchedGeometryEffect(
        id: "movement",
        in: namespace,
        properties: [.frame],
        isSource: false
      )

      .matchedGeometryEffect(
        id: "frame",
        in: namespace,
        properties: [.frame],
        isSource: isActive == false
      )

      .zIndex(isActive ? 0 : 1)

      item
    }


  }

  private struct __Stack: View {

    @State var detail: AnyView?
    @Namespace var namespace
    @State var menuOffset: CGSize = .zero

    var body: some View {

      ZStack {

        ZStack {

          VStack {

            if detail == nil {
              Link(namespace: namespace, isActive: detail != nil)
                .onTapGesture {

                  withAnimation(
                    .bouncy
                  ) {

                    addDetail()

                  }
                }
                .fixedSize()
                .frame(
                  maxWidth: .infinity,
                  maxHeight: .infinity,
                  alignment: .center
                )
                .transition(.blurReplace)
            }
          }

        }

        detail?.transition(.blurReplace)

      }


    }

    private func addDetail() {
      let destination = ContainerView {
        ZStack {

          VStack {
            HStack {
              Button("Dismiss") {
              }
            }
            Circle()
              .frame(
                width: 100,
                height: 100,
                alignment: .center
              )

            Circle()
              .frame(
                width: 100,
                height: 100,
                alignment: .center
              )

            Circle()
              .frame(
                width: 100,
                height: 100,
                alignment: .center
              )

            Text("HelloHelloHelloHelloHelloHelloHelloHelloHello")
          }
          .padding()
        }
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))

      }

        .matchedGeometryEffect(
          id: "movement",
          in: namespace,
          properties: [],
          isSource: true
        )


      .modifier(
        SnapDraggingModifier(
          gestureMode: .simultaneous,
          offset: $menuOffset,
          activation: .init(minimumDistance: 8),
          axis: [.horizontal, .vertical],
          horizontalBoundary: .init(min: -80, max: 80, bandLength: 120),
          verticalBoundary: .init(
            min: 0,
            max: .infinity,
            bandLength: 120
          ),
//          springParameter: .interpolation(
//            mass: 1,
//            stiffness: 80,
//            damping:
//              50
//          ),
          handler: .init(
            onEndDragging: {
              velocity,
              offset,
              contentSize in

              withAnimation(
                .smooth) {
                detail = nil
              }

              return .zero
            }
          )
        )
      )
      .matchedGeometryEffect(
        id: "frame",
        in: namespace,
        properties: [.frame],
        isSource: true
      )
      .fixedSize()


      detail = AnyView(destination)

    }
  }

  struct ContainerView<Content: View>: View {

    private let content: Content

    init(@ViewBuilder content: () -> Content) {
      self.content = content()
    }

    var body: some View {
      ZStack {
        Color.clear
        content
          .frame(
            minWidth: 0,
            minHeight: 0,
            alignment: .top
          )
      }
      .background(
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .fill(Color.clear)
      )
    }

  }

}
