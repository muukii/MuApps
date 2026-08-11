import SwiftUI

extension EnvironmentValues {
  /// The retained view levels owned by the nearest ``NavigationToolbar``.
  ///
  /// Append a type-erased view to push a level. Removing the last view returns
  /// to the preceding level.
  @Entry public var stackedView: Binding<[AnyView]> = .constant([])
}

/// A horizontal toolbar that retains pushed SwiftUI view levels.
///
/// Descendant content can use ``EnvironmentValues/stackedView`` to push a new
/// level. The toolbar keeps earlier levels mounted and provides a back button
/// while a pushed level is visible.
public struct NavigationToolbar<Root: View>: View {

  @Namespace private var namespace

  @State private var stackedView: [AnyView]

  private let root: Root
  private let usesGlass: Bool

  /// Creates a stack-based toolbar with root content.
  ///
  /// - Parameters:
  ///   - usesGlass: Whether toolbar surfaces use the interactive glass effect.
  ///   - initialStack: View levels that should initially appear above `root`.
  ///   - root: The toolbar's root content.
  public init(
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

  public var body: some View {
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
  fileprivate func map<U: View>(@ViewBuilder _ closure: (Self) -> U) -> some View {
    closure(self)
  }
}
