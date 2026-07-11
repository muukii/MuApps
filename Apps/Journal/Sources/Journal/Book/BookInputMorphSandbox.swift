#if os(iOS)
import NextGrowingTextViewSwiftUI
#else
import CaptureText
#endif
import SwiftUI
#if canImport(SwiftUISnapDraggingModifier)
import SwiftUISnapDraggingModifier
#endif

/// Minimal sandbox for experimenting with a bottom source surface morphing into a Book overlay.
///
/// This intentionally keeps product UI out of the way. The layout mirrors the
/// small playground sample: a stage, a morphing destination surface on that
/// stage, and a matched source surface inside the bottom safe-area inset.
struct BookInputMorphSandbox: View {

  /// Initial morph state used by previews and debug launch routes.
  enum InitialState {

    /// Shows the local stage surface without attaching it to the bottom source.
    case collapsed

    /// Shows the stage surface attached to the bottom source through matched geometry.
    case expanded
  }

  @State private var text: String = ""
  @State private var isExpanded: Bool
  @State private var destinationDragOffset: CGSize = .zero
  @Namespace private var namespace

  init(initialState: InitialState = .collapsed) {
    _isExpanded = State(initialValue: initialState == .expanded)
  }

  var body: some View {
    VStack {
      ZStack {
        Color.black
          .ignoresSafeArea()

        RoundedRectangle(cornerRadius: 28, style: .continuous)
          .fill(.green)
          .frame(height: 300)
          .padding(24)
          .overlay(alignment: .bottomLeading) {

          }
      }

      bottomView
    }
    //    .safeAreaInset(edge: .bottom) {
    //      BookInputMorphSource(
    //        namespace: namespace,
    //        onToggle: {
    //          toggle()
    //        }
    //      )
    //    }
    //    .safeAreaInset(
    //      edge: .bottom,
    //      content: {
    //        bottomView
    //      }
    //    )
    .animation(BookInputMorphMetrics.animation, value: isExpanded)
  }

  private var bottomView: some View {
    VStack {

      Color.clear
        //            .frame(height: BookInputMorphMetrics.sourceRegionHeight)
        .matchedGeometryEffect(
          id: BookInputMorphMatchedElement.activeSurface,
          in: namespace,
          isSource: true
        )

      HStack(alignment: .bottom) {

        BookInputMorphDestination(
          isExpanded: isExpanded,
          namespace: namespace,
          dragOffset: $destinationDragOffset,
          onActivate: {
            expand()
          },
          onDismissDrag: {
            collapse()
          },
          onSelectItem: { _ in
            collapse()
          }
        )
        .padding(44)

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
      //      .glassEffect(
      //        .regular.interactive(),
      //        in: .rect(cornerRadius: 24, style: .continuous)
      //      )
      //        .glassEffectTransition(.matchedGeometry)
      .padding(16)
    }
  }

  private func toggle() {
    if isExpanded {
      collapse()
    } else {
      expand()
    }
  }

  private func expand() {
    destinationDragOffset = .zero
    isExpanded = true
  }

  private func collapse() {
    destinationDragOffset = .zero
    isExpanded = false
  }
}

/// Visual constants for the morph sandbox.
private enum BookInputMorphMetrics {

  /// Height of the bottom safe-area source region, matching the playground sample.
  static let sourceRegionHeight: CGFloat = 200

  /// Resting width of the destination before it joins the bottom source.
  static let collapsedDestinationWidth: CGFloat = 200

  /// Fixed destination height used in both collapsed and expanded states.
  static let destinationHeight: CGFloat = 160

  /// Size of the visible source handle inside the bottom source region.
  static let sourceHandleSize = CGSize(width: 200, height: 64)

  /// Shared corner radius for source and destination surfaces.
  static let surfaceCornerRadius: CGFloat = 20

  /// Spring-like animation used by the sample-style morph.
  static let animation: Animation = .snappy
}

/// Stable identifiers for the sandbox's matched geometry pair.
private enum BookInputMorphMatchedElement {

  /// Active matched surface shared by the bottom source and expanded destination.
  static let activeSurface = "book-input-morph-active-surface"

  /// Unmatched resting surface used while the destination is collapsed.
  static let restingSurface = "book-input-morph-resting-surface"
}

/// Content state rendered inside the morphing destination surface.
private enum BookInputMorphDestinationContent {

  /// The collapsed surface shows only a local add affordance.
  case addButton

  /// The expanded surface shows sample menu rows.
  case menuItems

  init(isExpanded: Bool) {
    if isExpanded {
      self = .menuItems
    } else {
      self = .addButton
    }
  }
}

/// Destination surface shown on the stage.
private struct BookInputMorphDestination: View {

  let isExpanded: Bool
  let namespace: Namespace.ID
  @Binding var dragOffset: CGSize
  let onActivate: @MainActor @Sendable () -> Void
  let onDismissDrag: @MainActor @Sendable () -> Void
  let onSelectItem: @MainActor @Sendable (BookInputMorphMenuItem) -> Void

  var body: some View {
    Color.clear
    .overlay {
      BookInputMorphDestinationContentView(
        content: .init(isExpanded: isExpanded),
        onActivate: onActivate,
        onSelectItem: onSelectItem
      )
      .geometryGroup()
    }
    .clipShape(
      RoundedRectangle(cornerRadius: BookInputMorphMetrics.surfaceCornerRadius)
    )
    .animation(
      .smooth,
      body: {
        $0.glassEffect(
          { () -> Glass in
            switch isExpanded {
            case false: return .identity
            case true: return .regular
            }
          }().interactive(),
          in: .rect(cornerRadius: BookInputMorphMetrics.surfaceCornerRadius)
        )
      }
    )
    .modifier(
      SnapDraggingModifier(
        gestureMode: .simultaneous,
        offset: $dragOffset,
        activation: .init(minimumDistance: 8),
        axis: [.horizontal, .vertical],
        horizontalBoundary: .init(min: -46, max: 46, bandLength: 120),
        verticalBoundary: .init(min: 0, max: .infinity, bandLength: 140),
        springParameter: .interpolation(mass: 1, stiffness: 34, damping: 22),
        handler: .init(
          onEndDragging: { velocity, offset, contentSize in
            if isExpanded,
              shouldDismissMenu(
                velocity: velocity,
                offset: offset,
                contentSize: contentSize
              )
            {
              onDismissDrag()
            }

            return .zero
          }
        )
      )
    )
    .matchedGeometryEffect(
      id: isExpanded
        ? BookInputMorphMatchedElement.activeSurface
        : BookInputMorphMatchedElement.restingSurface,
      in: namespace,
      isSource: false
    )
  }

  private func shouldDismissMenu(
    velocity: CGVector,
    offset: CGSize,
    contentSize: CGSize
  ) -> Bool {
    velocity.dy > 760
      || offset.height > min(140, contentSize.height * 0.32)
  }
}

/// Switch-driven content inside the destination surface.
private struct BookInputMorphDestinationContentView: View {

  let content: BookInputMorphDestinationContent
  let onActivate: @MainActor @Sendable () -> Void
  let onSelectItem: @MainActor @Sendable (BookInputMorphMenuItem) -> Void

  var body: some View {
    ZStack {
      switch content {
      case .addButton:
        Button(action: onActivate) {
          Image(systemName: "plus")
            .font(.system(size: 30, weight: .regular))
            .foregroundStyle(.white)
            .frame(
              maxWidth: .infinity,
              maxHeight: .infinity,
              alignment: .center
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open Menu")

      case .menuItems:
        VStack(alignment: .leading, spacing: 0) {
          ForEach(BookInputMorphMenuItem.defaultItems) { item in
            Button {
              onSelectItem(item)
            } label: {
              BookInputMorphMenuRow(item: item)
            }
            .buttonStyle(.plain)
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.vertical, 10)
      }
    }

  }
}

/// Sample menu item shown by the sandbox when the destination is expanded.
private struct BookInputMorphMenuItem: Identifiable {

  /// Stable identity for SwiftUI diffing and menu selection.
  let id: String

  /// SF Symbol rendered at the leading edge of the row.
  let systemName: String

  /// Row title shown in the expanded sandbox state.
  let title: LocalizedStringResource

  /// Small sample menu for experimenting with surface content transitions.
  static let defaultItems: [Self] = [
    .init(id: "camera", systemName: "camera", title: "Camera"),
    .init(id: "photos", systemName: "photo", title: "Photos"),
    .init(id: "files", systemName: "paperclip", title: "Files"),
  ]
}

/// One menu-like row in the expanded destination surface.
private struct BookInputMorphMenuRow: View {

  let item: BookInputMorphMenuItem

  var body: some View {
    HStack(spacing: 14) {
      Image(systemName: item.systemName)
        .font(.system(size: 19, weight: .medium))
        .foregroundStyle(.white)
        .frame(width: 38, height: 38)
        .background(.white.opacity(0.16), in: Circle())

      Text(item.title)
        .font(.body.weight(.medium))
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, 16)
    .frame(height: 46)
    .contentShape(Rectangle())
  }
}

#Preview("Book Input Morph Sandbox") {
  BookInputMorphSandbox()
    .preferredColorScheme(.dark)
}

#Preview("Book Input Morph Sandbox Expanded") {
  BookInputMorphSandbox(initialState: .expanded)
    .preferredColorScheme(.dark)
}
