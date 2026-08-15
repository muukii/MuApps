import SwiftUI

/// Meaning of the currently visible composer.
///
/// Root composition creates a Home card. Continuation composition appends to
/// the card represented by the active detail destination.
enum CreationComposerPlacement {
  case root
  case continuation

  /// Whether this placement represents the Home root import surface.
  var acceptsHomeDrop: Bool {
    switch self {
    case .root:
      true
    case .continuation:
      false
    }
  }

  var prompt: LocalizedStringKey {
    switch self {
    case .root:
      "Write something"
    case .continuation:
      "Add to this card"
    }
  }

  var postAccessibilityLabel: LocalizedStringKey {
    switch self {
    case .root:
      "Post Entry"
    case .continuation:
      "Add Entry"
    }
  }
}

/// Presentation container for the Journal creation surface.
///
/// The container owns the bottom input bar and its standard SwiftUI `Menu`.
/// The caller continues to own draft mutation, capture style, and saving.
struct CreationContainer<Content: View, MenuContent: View>: View {

  private let draft: ThreadDraftCard
  private let isPresented: Bool
  private let placement: CreationComposerPlacement
  private let isProcessing: Bool
  private let onOpenDraft: @MainActor @Sendable () -> Void
  private let onDiscardDraft: @MainActor @Sendable () -> Void
  private let onPost: @MainActor @Sendable () -> Void
  private let onDropItems: @MainActor @Sendable ([HomeDropItem]) -> Void
  private let content: Content
  private let menuContent: MenuContent

  init(
    draft: ThreadDraftCard,
    isPresented: Bool = true,
    placement: CreationComposerPlacement = .root,
    isProcessing: Bool,
    onOpenDraft: @escaping @MainActor @Sendable () -> Void,
    onDiscardDraft: @escaping @MainActor @Sendable () -> Void,
    onPost: @escaping @MainActor @Sendable () -> Void,
    onDropItems: @escaping @MainActor @Sendable ([HomeDropItem]) -> Void,
    @ViewBuilder content: () -> Content,
    @ViewBuilder menuContent: () -> MenuContent
  ) {
    self.draft = draft
    self.isPresented = isPresented
    self.placement = placement
    self.isProcessing = isProcessing
    self.onOpenDraft = onOpenDraft
    self.onDiscardDraft = onDiscardDraft
    self.onPost = onPost
    self.onDropItems = onDropItems
    self.content = content()
    self.menuContent = menuContent()
  }

  @State private var composerHeight: CGFloat = 0

  var body: some View {
    content
      .environment(\.composerOverlayHeight, composerHeight)
      .safeAreaInset(edge: .bottom) {
        // The composer covers the whole navigation stack, so its height is
        // published rather than relied upon as a safe-area inset. An empty group
        // measures as zero, which clears the reservation with the composer.
        Group {
          if isPresented {
            CreationComposerInputBar(
              draft: draft,
              placement: placement,
              isProcessing: isProcessing,
              onOpenDraft: onOpenDraft,
              onDiscardDraft: onDiscardDraft,
              onPost: onPost
            ) {
              menuContent
            }
            .dropDestination(
              for: HomeDropItem.self,
              isEnabled: placement.acceptsHomeDrop && isProcessing == false
            ) { items, _ in
              onDropItems(items)
            }
            .frame(maxWidth: CreationContainerMetrics.maximumComposerWidth)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, CreationContainerMetrics.horizontalPadding)
            .padding(.bottom, 8)
          }
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
          proxy.size.height
        } action: { height in
          composerHeight = height
        }
      }
  }
}

extension EnvironmentValues {

  /// Height the floating composer covers at the bottom of every screen below it.
  ///
  /// The composer is installed outside the navigation stack so a single bar can
  /// follow every pushed screen. A `safeAreaInset` does not cross that boundary,
  /// so scrolling screens read this value and inset their own scroll content
  /// instead. Without it a list's last row can never be scrolled clear of the bar.
  @Entry var composerOverlayHeight: CGFloat = 0
}
