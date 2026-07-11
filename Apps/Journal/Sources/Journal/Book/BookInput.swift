#if os(iOS)
import NextGrowingTextViewSwiftUI
#else
import CaptureText
#endif
import SwiftUI
#if canImport(SwiftUISnapDraggingModifier)
import SwiftUISnapDraggingModifier
#endif

private struct _Book: View {

  @State private var text: String = ""
  @State private var isShowingMenu: Bool = false
  @State private var menuOffset: CGSize = .zero

  @Namespace private var namespace

  /// The downward distance that commits the overlay dismissal.
  private let menuDismissDistance: CGFloat = 140

  var body: some View {
    ScrollView {

    }
    .safeAreaInset(
      edge: .bottom,
      content: {
        VStack {

          Rectangle()
//            .opacity(0)
            .frame(height: 100)
            .matchedGeometryEffect(
              id: "destination",
              in: namespace,
              isSource: true
            )

          HStack(alignment: .bottom) {

            Color.clear
              .frame(width: 32,height: 32)
              .overlay {
              menuContainer
                  .offset(menuOffset)
                  .zIndex(2)
                .matchedGeometryEffect(
                  id: "destination",
                  in: namespace,
                  properties: isShowingMenu ? .position : [],
                  isSource: false
                )
            }
            .padding(.bottom, 2)
            .padding(.trailing, 1)

            GrowingTextEditor(
              text: $text,
              configuration: .init(
                minLines: 1,
                maxLines: 10,
                horizontalPadding: 0,
                verticalPadding: 0,
                lineSpacing: 2
              ),
              placeholder: {
                Text("What's on your mind?")
              }
            )

            Button {
              // Handle send action
            } label: {
              Circle()
                .foregroundStyle(.primary)
                .frame(width: 34, height: 34)
                .overlay {
                  Image(systemName: "arrow.up")
                    .foregroundStyle(.white)
                }
                .contentShape(Rectangle())
            }
            .padding(.bottom, 2)
            .padding(.trailing, 1)
          }
          .padding(.vertical, 6)
          .padding(.horizontal, 8)
          .padding(.leading, 4)
          .glassEffect(
            .regular.interactive(),
            in: .rect(cornerRadius: 24, style: .continuous)
          )
          //        .glassEffectTransition(.matchedGeometry)
          .padding(16)
        }

      }
    )
    //    .overlay {
    //      if isShowingMenu {
    //        Color.clear.hidden()
    //          .overlay(alignment: .bottom) {
    //            menuOverlay
    //          }
    //          .transition(.scale(0).combined(with: .opacity))
    //          .matchedGeometryEffect(
    //            id: "destination",
    //            in: namespace,
    //            properties: .frame,
    //            anchor: .center,
    //            isSource: false,
    //          )
    //      }
    //    }

  }

  @ViewBuilder
  private var menuContainer: some View {
    ZStack {
      Color.red
      if isShowingMenu {
        menuOverlay
          .transition(.opacity)

      } else {
        Button {
          withAnimation(.smooth) {
            isShowingMenu = true
          }
        } label: {
          Circle()
            .foregroundStyle(.primary)
            .frame(width: 34, height: 34)
            .overlay {
              Image(systemName: "arrow.up")
                .foregroundStyle(.white)
            }
            .contentShape(Rectangle())

        }
        .transition(.opacity)
      }
    }
    .geometryGroup()

  }

  private var menuOverlay: some View {

    ZStack {
      VStack {
        Button("Dismiss") {
        }
        RoundedRectangle(cornerRadius: 24, style: .continuous)
          .frame(width: 300, height: 100)
        Button("Dismiss") {
        }
        Button("Dismiss") {
        }
      }
    }
    .padding()
    .glassEffect(
      .regular.interactive(),
      in: .rect(cornerRadius: 24, style: .continuous)
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
        springParameter: .interpolation(
          mass: 1,
          stiffness: 30,
          damping: 20
        ),
        handler: .init(
          onEndDragging: { velocity, offset, contentSize in
            if shouldDismissMenu(
              velocity: velocity,
              offset: offset,
              contentSize: contentSize
            ) {

              withAnimation {
                isShowingMenu = false
              }

              return .zero
            }

            return .zero
          }
        )
      )
    )
    .scaleEffect(menuOverlayScale, anchor: .center)
  }

  private var menuOverlayScale: CGFloat {
    if menuOffset.height > 0 {
      return 1 - min(menuOffset.height / 1200, 0.08)
    }

    return 1 + min(abs(menuOffset.height) / 2400, 0.025)
  }

  private func shouldDismissMenu(
    velocity: CGVector,
    offset: CGSize,
    contentSize: CGSize
  ) -> Bool {
    velocity.dy > 800
      || offset.height > min(menuDismissDistance, contentSize.height * 0.28)
  }

}

#Preview("Input") {
  _Book()
}

/// A transient arc offset layered on top of the matched-geometry movement.
private struct BookInputArcOffsetEffect: GeometryEffect {

  /// Linear transition progress. The visual offset maps this to `0 -> peak -> 0`.
  var progress: CGFloat

  /// The maximum offset applied halfway through the transition.
  let peakOffset: CGSize

  var animatableData: CGFloat {
    get {
      progress
    }
    set {
      progress = newValue
    }
  }

  func effectValue(size: CGSize) -> ProjectionTransform {
    let arcFraction = sin(progress * .pi)
    let transform = CGAffineTransform(
      translationX: peakOffset.width * arcFraction,
      y: peakOffset.height * arcFraction
    )

    return ProjectionTransform(transform)
  }
}

extension CGFloat {

  /// Returns this value constrained to the supplied closed range.
  fileprivate func clamped(to range: ClosedRange<Self>) -> Self {
    Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
  }
}
