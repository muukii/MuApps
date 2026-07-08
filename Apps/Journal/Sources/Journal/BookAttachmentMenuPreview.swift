import SwiftUI
import SwiftUISnapDraggingModifier

/// Preview-only Book surface for iterating on an input-attached menu.
///
/// This is intentionally not connected to the Journal creation flow. It keeps
/// the geometry, glass treatment, and drag-dismiss behavior isolated so the
/// menu can be tuned against reference recordings before being productized.
struct BookAttachmentMenuPreview: View {

  /// Initial presentation state used by static previews.
  enum InitialMenuState {

    /// Shows only the bottom input bar.
    case collapsed

    /// Shows the input bar with the attachment menu already expanded.
    case expanded
  }

  @State private var inputText: String = ""
  @State private var isMenuPresented: Bool
  @State private var menuOffset: CGSize = .zero

  @Namespace private var menuNamespace

  init(initialMenuState: InitialMenuState = .collapsed) {
    _isMenuPresented = State(initialValue: initialMenuState == .expanded)
  }

  var body: some View {
    ZStack(alignment: .bottomLeading) {
      BookAttachmentReferenceScene()
        .blur(radius: isMenuPresented ? 1.2 : 0)
        .allowsHitTesting(isMenuPresented == false)

      if isMenuPresented {
        BookAttachmentDismissLayer {
          dismissMenu()
        }
        .transition(.opacity)
      }

      if isMenuPresented {
        BookAttachmentMenuPanel(
          items: BookAttachmentMenuItem.defaultItems,
          namespace: menuNamespace,
          dragOffset: $menuOffset,
          onSelect: { _ in
            dismissMenu()
          },
          onDismissDrag: {
            dismissMenu()
          }
        )
        .offset(menuOffset)
        .scaleEffect(menuScale, anchor: .bottomLeading)
        .padding(.leading, BookAttachmentMenuMetrics.horizontalPadding)
        .padding(.bottom, BookAttachmentMenuMetrics.panelBottomPadding)
        .zIndex(2)
        .transition(.opacity)
      }
    }
    .animation(BookAttachmentMenuMetrics.presentationAnimation, value: isMenuPresented)
    .animation(BookAttachmentMenuMetrics.dragAnimation, value: menuOffset)
    .safeAreaInset(edge: .bottom) {
      BookAttachmentInputBar(
        text: $inputText,
        isMenuPresented: isMenuPresented,
        namespace: menuNamespace,
        onToggleMenu: {
          toggleMenu()
        }
      )
      .padding(.horizontal, BookAttachmentMenuMetrics.horizontalPadding)
      .padding(.bottom, 8)
    }
    .background(.black)
    .ignoresSafeArea(.keyboard)
  }

  private var menuScale: CGFloat {
    if menuOffset.height > 0 {
      return 1 - min(menuOffset.height / 1300, 0.075)
    }

    return 1 + min(abs(menuOffset.height) / 2800, 0.022)
  }

  private func toggleMenu() {
    withAnimation(BookAttachmentMenuMetrics.presentationAnimation) {
      if isMenuPresented {
        dismissMenu()
      } else {
        menuOffset = .zero
        isMenuPresented = true
      }
    }
  }

  private func dismissMenu() {
    withAnimation(BookAttachmentMenuMetrics.presentationAnimation) {
      menuOffset = .zero
      isMenuPresented = false
    }
  }
}

/// Visual constants for the Book attachment menu prototype.
private enum BookAttachmentMenuMetrics {

  /// Horizontal screen inset shared by the input bar and the floating panel.
  static let horizontalPadding: CGFloat = 22

  /// Distance from the bottom safe area to the lower edge of the expanded panel.
  static let panelBottomPadding: CGFloat = -6

  /// Width of the expanded attachment panel.
  static let panelWidth: CGFloat = 300

  /// Size of the matched-geometry source anchored under the `+` button.
  static let surfaceSourceSize: CGFloat = 48

  /// Corner radius used by the panel's glass surface.
  static let panelCornerRadius: CGFloat = 32

  /// Primary animation used when the menu opens and closes.
  static let presentationAnimation: Animation = .smooth(duration: 0.24)

  /// Lightweight animation used when the drag offset is reset.
  static let dragAnimation: Animation = .smooth(duration: 0.18)
}

/// Stable identifiers for matched geometry elements in the prototype.
private enum BookAttachmentMatchedElement {

  /// The glass surface that visually grows from the `+` affordance into panel.
  static let attachmentSurface = "book-attachment-menu-surface"
}

/// Static scene content that gives the translucent panel something to refract.
private struct BookAttachmentReferenceScene: View {

  var body: some View {
    VStack(spacing: 0) {
      BookAttachmentTopBar()

      Spacer(minLength: 0)

      BookAttachmentPromptList()
        .padding(.horizontal, BookAttachmentMenuMetrics.horizontalPadding)
        .padding(.bottom, 18)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.black)
  }
}

/// A compact top bar matching the reference surface enough for preview tuning.
private struct BookAttachmentTopBar: View {

  var body: some View {
    HStack(spacing: 12) {
      CircleIconButton(systemName: "line.3.horizontal")

      Text("Book")
        .font(.title3.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 20)
        .frame(height: 48)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 24, style: .continuous))

      Spacer(minLength: 0)

      CircleIconButton(systemName: "bubble.left.and.bubble.right")
    }
    .padding(.horizontal, 22)
    .padding(.top, 20)
  }
}

/// Bottom suggestions that sit behind the attachment panel in the preview.
private struct BookAttachmentPromptList: View {

  private let prompts: [BookAttachmentPrompt] = [
    .init(systemName: "camera.aperture", title: "Capture a moment"),
    .init(systemName: "photo.on.rectangle", title: "Add from Photos"),
    .init(systemName: "globe", title: "Look something up"),
    .init(systemName: "square.stack.3d.up", title: "Choose a project"),
  ]

  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      ForEach(prompts) { prompt in
        HStack(spacing: 18) {
          Image(systemName: prompt.systemName)
            .font(.title3.weight(.medium))
            .frame(width: 26)
            .foregroundStyle(.white.opacity(0.78))

          Text(prompt.title)
            .font(.title3)
            .foregroundStyle(.white.opacity(0.72))
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// Text and icon shown in one preview prompt row.
private struct BookAttachmentPrompt: Identifiable {

  /// Stable identity for preview-only prompt rows.
  var id: String { systemName }

  /// SF Symbol rendered at the leading edge.
  let systemName: String

  /// Localized prompt title.
  let title: LocalizedStringResource
}

/// The bottom input bar that owns the menu source affordance.
private struct BookAttachmentInputBar: View {

  @Binding var text: String

  let isMenuPresented: Bool
  let namespace: Namespace.ID
  let onToggleMenu: @MainActor @Sendable () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Button(action: onToggleMenu) {
        Image(systemName: "plus")
          .font(.system(size: 24, weight: .regular))
          .rotationEffect(.degrees(isMenuPresented ? 45 : 0))
          .foregroundStyle(.white)
          .frame(width: 38, height: 42)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(isMenuPresented ? "Close Attachments" : "Open Attachments")

      TextField("Ask Book", text: $text, axis: .vertical)
        .font(.body)
        .lineLimit(1...5)
        .textFieldStyle(.plain)
        .foregroundStyle(.white)
        .tint(.white)

      Spacer(minLength: 0)

      Image(systemName: "mic")
        .font(.system(size: 23, weight: .regular))
        .foregroundStyle(.white.opacity(0.92))
        .frame(width: 34, height: 42)

      Button {
      } label: {
        Image(systemName: "waveform")
          .font(.system(size: 20, weight: .semibold))
          .foregroundStyle(.black)
          .frame(width: 44, height: 44)
          .background(.white, in: Circle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Start Voice")
    }
    .padding(.leading, 6)
    .padding(.trailing, 6)
    .frame(minHeight: 58)
    .background(alignment: .leading) {
      BookAttachmentMenuSurfaceSource(namespace: namespace)
        .padding(.leading, 1)

      if isMenuPresented {
        Circle()
          .fill(.regularMaterial)
          .frame(
            width: BookAttachmentMenuMetrics.surfaceSourceSize,
            height: BookAttachmentMenuMetrics.surfaceSourceSize
          )
          .padding(.leading, 1)
          .allowsHitTesting(false)
      }
    }
    .background {
      RoundedRectangle(cornerRadius: 29, style: .continuous)
        .fill(.regularMaterial)
    }
    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 29, style: .continuous))
  }
}

/// Floating attachment choices shown above the bottom input bar.
private struct BookAttachmentMenuPanel: View {

  let items: [BookAttachmentMenuItem]
  let namespace: Namespace.ID
  @Binding var dragOffset: CGSize
  let onSelect: @MainActor @Sendable (BookAttachmentMenuItem) -> Void
  let onDismissDrag: @MainActor @Sendable () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      ForEach(items) { item in
        Button {
          onSelect(item)
        } label: {
          BookAttachmentMenuRow(item: item)
        }
        .buttonStyle(.plain)
      }
    }
    .padding(.vertical, 16)
    .frame(width: BookAttachmentMenuMetrics.panelWidth, alignment: .leading)
    .background {
      RoundedRectangle(
        cornerRadius: BookAttachmentMenuMetrics.panelCornerRadius,
        style: .continuous
      )
      .fill(.clear)
      .matchedGeometryEffect(
        id: BookAttachmentMatchedElement.attachmentSurface,
        in: namespace,
        properties: .frame,
        anchor: .bottomLeading,
        isSource: false
      )
      .background {
        RoundedRectangle(
          cornerRadius: BookAttachmentMenuMetrics.panelCornerRadius,
          style: .continuous
        )
        .fill(.regularMaterial)
      }
    }
    .overlay {
      RoundedRectangle(
        cornerRadius: BookAttachmentMenuMetrics.panelCornerRadius,
        style: .continuous
      )
      .strokeBorder(.white.opacity(0.1), lineWidth: 1)
    }
    .shadow(color: .black.opacity(0.38), radius: 26, x: 0, y: 18)
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
            if shouldDismissMenu(
              velocity: velocity,
              offset: offset,
              contentSize: contentSize
            ) {
              onDismissDrag()
            }

            return .zero
          }
        )
      )
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

/// Source surface that keeps the menu morph anchored to the `+` affordance.
private struct BookAttachmentMenuSurfaceSource: View {

  let namespace: Namespace.ID

  var body: some View {
    RoundedRectangle(cornerRadius: 30, style: .continuous)
      .fill(.regularMaterial)
      .frame(
        width: BookAttachmentMenuMetrics.surfaceSourceSize,
        height: BookAttachmentMenuMetrics.surfaceSourceSize
      )
      .matchedGeometryEffect(
        id: BookAttachmentMatchedElement.attachmentSurface,
        in: namespace,
        properties: .frame,
        anchor: .center,
        isSource: true
      )
      .allowsHitTesting(false)
  }
}

/// One row in the floating attachment menu.
private struct BookAttachmentMenuRow: View {

  let item: BookAttachmentMenuItem

  var body: some View {
    HStack(spacing: 18) {
      Image(systemName: item.systemName)
        .font(.system(size: 22, weight: .medium))
        .foregroundStyle(.white)
        .frame(width: 54, height: 54)
        .background(.white.opacity(0.1), in: Circle())

      Text(item.title)
        .font(.title2.weight(.regular))
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, 18)
    .frame(height: 68)
    .contentShape(Rectangle())
  }
}

/// Menu action model for the Book attachment preview.
private struct BookAttachmentMenuItem: Identifiable {

  /// Stable identity for SwiftUI diffing and row selection.
  let id: String

  /// SF Symbol used by the row icon.
  let systemName: String

  /// Localized title shown to the user.
  let title: LocalizedStringResource

  /// Reference-like menu choices used by the prototype.
  static let defaultItems: [Self] = [
    .init(id: "camera", systemName: "camera", title: "Camera"),
    .init(id: "photos", systemName: "photo", title: "Photos"),
    .init(id: "files", systemName: "paperclip", title: "Files"),
    .init(id: "plugins", systemName: "sparkles", title: "Plugins"),
  ]
}

/// Transparent layer that catches taps outside the open menu.
private struct BookAttachmentDismissLayer: View {

  let onDismiss: @MainActor @Sendable () -> Void

  var body: some View {
    Rectangle()
      .fill(.black.opacity(0.001))
      .ignoresSafeArea()
      .contentShape(Rectangle())
      .onTapGesture {
        onDismiss()
      }
  }
}

/// Circular glass button used in the fake top bar.
private struct CircleIconButton: View {

  let systemName: String

  var body: some View {
    Image(systemName: systemName)
      .font(.system(size: 20, weight: .medium))
      .foregroundStyle(.white)
      .frame(width: 52, height: 52)
      .glassEffect(.regular.interactive(), in: .circle)
  }
}

#Preview("Book Attachment Menu") {
  BookAttachmentMenuPreview()
    .preferredColorScheme(.dark)
}

#Preview("Book Attachment Menu Open") {
  BookAttachmentMenuPreview(initialMenuState: .expanded)
    .preferredColorScheme(.dark)
}
