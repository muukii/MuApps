import SwiftUI

extension EnvironmentValues {
  @Entry var stackedView: Binding<[AnyView]> = .constant([])
}

struct NavigationToolbar<Root: View>: View {

  @Namespace var namespace

  @State var stackedView: [AnyView] = []

  let root: Root
  private let usesGlass: Bool

  init(
    usesGlass: Bool = true,
    initialStack: [AnyView] = [],
    @ViewBuilder root: () -> Root
  ) {
    self.usesGlass = usesGlass
    _stackedView = State(initialValue: initialStack)
    self.root = root()
  }

  private var glass: Glass {
    .regular
  }

  var body: some View {
    HStack {

      ZStack {

        GlassEffectContainer {
          root
            .map {
              if usesGlass {
                $0.glassEffect(glass.interactive())
              } else {
                $0
              }
            }
        }
        .opacity(stackedView.isEmpty ? 1 : 0)
        .blur(radius: stackedView.isEmpty ? 0 : 8)

        ForEach(stackedView.enumerated(), id: \.offset) { index, view in

          GlassEffectContainer {
            HStack {

              if stackedView.isEmpty == false {
                backButton
              }

              view
                .map {
                  if usesGlass {
                    $0.glassEffect(glass.interactive())
                  } else {
                    $0
                  }
                }
            }
          }
          .transition(.blurReplace.animation(.smooth))
          .opacity(index == stackedView.indices.last ? 1 : 0)
          .blur(radius: index == stackedView.indices.last ? 0 : 8)
        }

      }
     
      .environment(\.stackedView, $stackedView)

    }
    .fixedSize(horizontal: false, vertical: true)
    .animation(.smooth, value: stackedView.count)
  }

  private var backButton: some View {
    Button {
      stackedView.removeLast()
    } label: {
      Image(systemName: "chevron.backward")
        .padding(12)
    }
    .map {
      if usesGlass {
        $0.glassEffect(glass.interactive())
      } else {
        $0
      }
    }

  }

}

extension View {
  func map<U: View>(@ViewBuilder _ closure: (Self) -> U) -> some View {
    closure(self)
  }
}
