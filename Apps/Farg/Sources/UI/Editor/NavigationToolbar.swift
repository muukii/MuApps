import SwiftUI

extension EnvironmentValues {
  @Entry var stackedView: Binding<[AnyView]> = .constant([])
}

struct NavigationToolbar<Root: View>: View {

  @Namespace var namespace

  @State var stackedView: [AnyView] = []

  let root: Root

  init(@ViewBuilder root: () -> Root) {
    self.root = root()
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
        .glassEffect(.regular.interactive())
        //        .frame(maxWidth: .infinity, alignment: .center)

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
    .glassEffect(.regular.interactive())
    .glassEffectTransition(.matchedGeometry)

  }

}
