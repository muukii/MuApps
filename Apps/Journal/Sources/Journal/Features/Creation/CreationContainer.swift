import SwiftUI

/// Persistence relationship represented by the currently visible composer.
///
/// Root composition creates a Home card. Reply composition appends a child to
/// an explicitly selected tree placement without depending on navigation.
enum CreationComposerPlacement {
  case root
  case reply

  /// Whether this placement represents the Home root import surface.
  var acceptsHomeDrop: Bool {
    switch self {
    case .root:
      true
    case .reply:
      false
    }
  }

  var prompt: LocalizedStringKey {
    switch self {
    case .root:
      "Write something"
    case .reply:
      "Write a reply"
    }
  }

  var postAccessibilityLabel: LocalizedStringKey {
    switch self {
    case .root:
      "Post Entry"
    case .reply:
      "Post Reply"
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
  private let replyTarget: SavedListReplyTarget?
  private let isReplyTargetAvailable: Bool
  private let isPostDestinationAvailable: Bool
  private let focusRequestID: UUID?
  private let onConsumeFocusRequest: @MainActor @Sendable (UUID) -> Bool
  private let isProcessing: Bool
  private let onOpenDraft: @MainActor @Sendable () -> Void
  private let onDiscardDraft: @MainActor @Sendable () -> Void
  private let onPost: @MainActor @Sendable () -> Void
  private let onCancelReply: @MainActor @Sendable () -> Void
  private let onDropItems: @MainActor @Sendable ([HomeDropItem]) -> Void
  private let content: Content
  private let menuContent: MenuContent

  init(
    draft: ThreadDraftCard,
    isPresented: Bool = true,
    placement: CreationComposerPlacement = .root,
    replyTarget: SavedListReplyTarget? = nil,
    isReplyTargetAvailable: Bool = true,
    isPostDestinationAvailable: Bool = true,
    focusRequestID: UUID? = nil,
    onConsumeFocusRequest: @escaping @MainActor @Sendable (UUID) -> Bool = { _ in false },
    isProcessing: Bool,
    onOpenDraft: @escaping @MainActor @Sendable () -> Void,
    onDiscardDraft: @escaping @MainActor @Sendable () -> Void,
    onPost: @escaping @MainActor @Sendable () -> Void,
    onCancelReply: @escaping @MainActor @Sendable () -> Void = {},
    onDropItems: @escaping @MainActor @Sendable ([HomeDropItem]) -> Void,
    @ViewBuilder content: () -> Content,
    @ViewBuilder menuContent: () -> MenuContent
  ) {
    self.draft = draft
    self.isPresented = isPresented
    self.placement = placement
    self.replyTarget = replyTarget
    self.isReplyTargetAvailable = isReplyTargetAvailable
    self.isPostDestinationAvailable = isPostDestinationAvailable
    self.focusRequestID = focusRequestID
    self.onConsumeFocusRequest = onConsumeFocusRequest
    self.isProcessing = isProcessing
    self.onOpenDraft = onOpenDraft
    self.onDiscardDraft = onDiscardDraft
    self.onPost = onPost
    self.onCancelReply = onCancelReply
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
            VStack(spacing: 8) {
              if let replyTarget {
                CreationReplyTargetStrip(
                  summary: replyTarget.displaySummary,
                  isAvailable: isReplyTargetAvailable,
                  onCancelReply: onCancelReply
                )
              }

              CreationComposerInputBar(
                draft: draft,
                placement: placement,
                isPostDestinationAvailable: isPostDestinationAvailable,
                focusRequestID: focusRequestID,
                onConsumeFocusRequest: onConsumeFocusRequest,
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

/// Detached Reply context displayed independently above the input bar.
///
/// The target summary is a value captured when Reply was selected. An
/// unavailable target remains visible so authored input never silently changes
/// from a child Reply into a new Home root.
struct CreationReplyTargetStrip: View {

  let summary: String
  let isAvailable: Bool
  let onCancelReply: @MainActor @Sendable () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: isAvailable ? "arrowshape.turn.up.left" : "exclamationmark.triangle")
        .foregroundStyle(isAvailable ? Color.secondary : Color.orange)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 2) {
        Text("Replying to", comment: "Label above the composer for the selected Reply target.")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)

        Text(summary)
          .font(.subheadline)
          .lineLimit(1)

        if isAvailable == false {
          Text(
            "Reply target is no longer available",
            comment: "Error shown when the selected parent card was deleted or became unavailable."
          )
          .font(.caption)
          .foregroundStyle(.orange)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      Button(action: onCancelReply) {
        Label(
          "Cancel Reply",
          systemImage: "xmark"
        )
        .font(.caption.weight(.semibold))
      }
      .buttonStyle(.plain)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(.regularMaterial, in: .rect(cornerRadius: 18, style: .continuous))
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
