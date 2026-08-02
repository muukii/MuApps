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
    GlassEffectContainer(spacing: 10) {
      HStack {

        ZStack {

          Group {
            if let top = stackedView.last {
              top
            } else {
              root
            }
          }
          .transition(.blurReplace)

        }
        .environment(\.stackedView, $stackedView)
        .map {
          if usesGlass {
            $0.glassEffect(glass.interactive())
          } else {
            $0
          }
        }

        if stackedView.isEmpty == false {
          backButton
        }

      }
      .fixedSize(horizontal: false, vertical: true)
    }
    .animation(.bouncy, value: stackedView.count)
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
