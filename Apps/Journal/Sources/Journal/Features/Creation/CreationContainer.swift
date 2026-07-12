import AppUIComponents
import CaptureAudio
import CaptureBauhaus
import CaptureDoodle
import CapturePhoto
import Foundation
import JournalVault
import MuColor
import SwiftUI

/// Presentation container for the Journal creation surface.
///
/// The container owns the bottom input bar and its standard SwiftUI `Menu`.
/// The caller continues to own draft mutation, capture presentation, and saving.
struct CreationContainer<Content: View, MenuContent: View>: View {

  private let draft: ThreadDraftCard
  private let isProcessing: Bool
  private let onOpenDraft: @MainActor @Sendable () -> Void
  private let onDiscardDraft: @MainActor @Sendable () -> Void
  private let onPost: @MainActor @Sendable () -> Void
  private let content: Content
  private let menuContent: MenuContent

  init(
    draft: ThreadDraftCard,
    isProcessing: Bool,
    onOpenDraft: @escaping @MainActor @Sendable () -> Void,
    onDiscardDraft: @escaping @MainActor @Sendable () -> Void,
    onPost: @escaping @MainActor @Sendable () -> Void,
    @ViewBuilder content: () -> Content,
    @ViewBuilder menuContent: () -> MenuContent
  ) {
    self.draft = draft
    self.isProcessing = isProcessing
    self.onOpenDraft = onOpenDraft
    self.onDiscardDraft = onDiscardDraft
    self.onPost = onPost
    self.content = content()
    self.menuContent = menuContent()
  }

  var body: some View {
    content
      .safeAreaInset(edge: .bottom) {
        CreationComposerInputBar(
          draft: draft,
          isProcessing: isProcessing,
          onOpenDraft: onOpenDraft,
          onDiscardDraft: onDiscardDraft,
          onPost: onPost
        ) {
          menuContent
        }
        .frame(maxWidth: CreationContainerMetrics.maximumComposerWidth)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, CreationContainerMetrics.horizontalPadding)
        .padding(.bottom, 8)
      }
  }
}

/// Visual constants for the creation composer bar.
private enum CreationContainerMetrics {

  /// Horizontal screen inset for the bottom composer.
  static let horizontalPadding: CGFloat = 16

  /// Keeps the pointer-driven Mac input surface within a readable line length.
  static let maximumComposerWidth: CGFloat = {
    #if os(macOS)
    720
    #else
    .infinity
    #endif
  }()

  /// Square visual length used by expanded authored-content previews.
  static let expandedSquarePreviewDimension: CGFloat = 220

  /// Shorter square length that leaves useful content visible in landscape.
  static let compactHeightSquarePreviewDimension: CGFloat = 160

  /// Height for the native rich-link card inside an expanded composer.
  static let expandedLinkPreviewHeight: CGFloat = 160

  /// Landscape height for the native rich-link card.
  static let compactHeightLinkPreviewHeight: CGFloat = 112

  /// Height for the wide ambient-audio waveform.
  static let expandedAudioPreviewHeight: CGFloat = 84

  /// Landscape height for the wide ambient-audio waveform.
  static let compactHeightAudioPreviewHeight: CGFloat = 72

}

/// Geometry of authored content that expands beyond the one-line composer.
private enum CreationComposerExpandedPreviewLayout: Hashable, Sendable {
  case square
  case link
  case audio
}

/// Bottom composer bar that owns the visible state of one unpublished card.
private struct CreationComposerInputBar<MenuContent: View>: View {

  @Bindable var draft: ThreadDraftCard
  let isProcessing: Bool
  let onOpenDraft: @MainActor @Sendable () -> Void
  let onDiscardDraft: @MainActor @Sendable () -> Void
  let onPost: @MainActor @Sendable () -> Void
  let menuContent: MenuContent

  init(
    draft: ThreadDraftCard,
    isProcessing: Bool,
    onOpenDraft: @escaping @MainActor @Sendable () -> Void,
    onDiscardDraft: @escaping @MainActor @Sendable () -> Void,
    onPost: @escaping @MainActor @Sendable () -> Void,
    @ViewBuilder menuContent: () -> MenuContent
  ) {
    self.draft = draft
    self.isProcessing = isProcessing
    self.onOpenDraft = onOpenDraft
    self.onDiscardDraft = onDiscardDraft
    self.onPost = onPost
    self.menuContent = menuContent()
  }

  var body: some View {
    if let previewLayout = draft.expandedComposerPreviewLayout {
      CreationComposerExpandedPreviewInputBar(
        draft: draft,
        previewLayout: previewLayout,
        isProcessing: isProcessing,
        onOpenDraft: onOpenDraft,
        onDiscardDraft: onDiscardDraft,
        onPost: onPost
      )
    } else {
      CreationComposerCompactInputBar(
        draft: draft,
        isProcessing: isProcessing,
        onOpenDraft: onOpenDraft,
        onDiscardDraft: onDiscardDraft,
        onPost: onPost
      ) {
        menuContent
      }
    }
  }
}

/// One-line composer used by text and compact non-media card kinds.
private struct CreationComposerCompactInputBar<MenuContent: View>: View {

  @Bindable var draft: ThreadDraftCard
  let isProcessing: Bool
  let onOpenDraft: @MainActor @Sendable () -> Void
  let onDiscardDraft: @MainActor @Sendable () -> Void
  let onPost: @MainActor @Sendable () -> Void
  let menuContent: MenuContent

  init(
    draft: ThreadDraftCard,
    isProcessing: Bool,
    onOpenDraft: @escaping @MainActor @Sendable () -> Void,
    onDiscardDraft: @escaping @MainActor @Sendable () -> Void,
    onPost: @escaping @MainActor @Sendable () -> Void,
    @ViewBuilder menuContent: () -> MenuContent
  ) {
    self.draft = draft
    self.isProcessing = isProcessing
    self.onOpenDraft = onOpenDraft
    self.onDiscardDraft = onDiscardDraft
    self.onPost = onPost
    self.menuContent = menuContent()
  }

  var body: some View {
    HStack(alignment: .bottom, spacing: 10) {
      CreationComposerLeadingAction(
        showsAddMenu: draft.isEmptyTextDraft,
        isProcessing: isProcessing,
        onDiscardDraft: onDiscardDraft
      ) {
        menuContent
      }

      CreationComposerDraftContent(
        draft: draft,
        isProcessing: isProcessing,
        onOpenDraft: onOpenDraft
      )

      CreationComposerPostButton(
        canPost: draft.canSave,
        isProcessing: isProcessing,
        onPost: onPost
      )
    }
    .padding(.leading, 6)
    .padding(.trailing, 6)
    .frame(minHeight: 58)
    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 29, style: .continuous))
  }
}

/// Expanded composer shared by large visual, link, and audio previews.
private struct CreationComposerExpandedPreviewInputBar: View {

  let draft: ThreadDraftCard
  let previewLayout: CreationComposerExpandedPreviewLayout
  let isProcessing: Bool
  let onOpenDraft: @MainActor @Sendable () -> Void
  let onDiscardDraft: @MainActor @Sendable () -> Void
  let onPost: @MainActor @Sendable () -> Void

  var body: some View {
    HStack(alignment: .bottom, spacing: 10) {
      CreationComposerLeadingAction(
        showsAddMenu: false,
        isProcessing: isProcessing,
        onDiscardDraft: onDiscardDraft
      ) {
        EmptyView()
      }

      Button(action: onOpenDraft) {
        CreationComposerExpandedPreviewSurface(
          payload: draft.previewPayload,
          layout: previewLayout
        )
      }
      .buttonStyle(.plain)
      .frame(maxWidth: .infinity)
      .disabled(isProcessing)
      .accessibilityLabel("Edit Card")
      .accessibilityValue(Text(draft.kind.displayTitle))

      CreationComposerPostButton(
        canPost: draft.canSave,
        isProcessing: isProcessing,
        onPost: onPost
      )
    }
    .padding(6)
    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 29, style: .continuous))
  }
}

/// Authored preview surface whose geometry follows the card modality.
private struct CreationComposerExpandedPreviewSurface: View {

  @Environment(\.verticalSizeClass) private var verticalSizeClass

  let payload: CardPreviewPayload
  let layout: CreationComposerExpandedPreviewLayout

  var body: some View {
    switch layout {
    case .square:
      CreationComposerExpandedPreviewCanvas {
        CardPreviewContent(
          payload: payload,
          presentation: .draftSummary
        )
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: squarePreviewDimension)
      }
    case .link:
      CreationComposerExpandedPreviewCanvas {
        CardPreviewContent(
          payload: payload,
          presentation: .draftSummary
        )
        .frame(maxWidth: .infinity)
        .frame(height: linkPreviewHeight)
      }
    case .audio:
      CreationComposerExpandedPreviewCanvas {
        CardPreviewContent(
          payload: payload,
          presentation: .draftSummary
        )
        .frame(maxWidth: .infinity)
        .frame(height: audioPreviewHeight)
      }
    }
  }

  private var squarePreviewDimension: CGFloat {
    if verticalSizeClass == .compact {
      return CreationContainerMetrics.compactHeightSquarePreviewDimension
    }

    return CreationContainerMetrics.expandedSquarePreviewDimension
  }

  private var linkPreviewHeight: CGFloat {
    if verticalSizeClass == .compact {
      return CreationContainerMetrics.compactHeightLinkPreviewHeight
    }

    return CreationContainerMetrics.expandedLinkPreviewHeight
  }

  private var audioPreviewHeight: CGFloat {
    if verticalSizeClass == .compact {
      return CreationContainerMetrics.compactHeightAudioPreviewHeight
    }

    return CreationContainerMetrics.expandedAudioPreviewHeight
  }
}

/// Shared clipping and accessibility treatment for an expanded preview.
private struct CreationComposerExpandedPreviewCanvas<Content: View>: View {

  let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    content
      .background(.background.opacity(0.72))
      .clipShape(.rect(cornerRadius: 23, style: .continuous))
      .allowsHitTesting(false)
      .accessibilityHidden(true)
      .contentShape(Rectangle())
  }
}

/// Leading composer action: add while empty, explicit discard once authored.
private struct CreationComposerLeadingAction<MenuContent: View>: View {

  let showsAddMenu: Bool
  let isProcessing: Bool
  let onDiscardDraft: @MainActor @Sendable () -> Void
  let menuContent: MenuContent

  init(
    showsAddMenu: Bool,
    isProcessing: Bool,
    onDiscardDraft: @escaping @MainActor @Sendable () -> Void,
    @ViewBuilder menuContent: () -> MenuContent
  ) {
    self.showsAddMenu = showsAddMenu
    self.isProcessing = isProcessing
    self.onDiscardDraft = onDiscardDraft
    self.menuContent = menuContent()
  }

  var body: some View {
    if showsAddMenu {
      Menu {
        menuContent
      } label: {
        Image(systemName: "plus")
          .font(.system(size: 24, weight: .regular))
          .frame(width: 44, height: 44)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(isProcessing)
      .accessibilityLabel("Add Card")
    } else {
      Button(action: onDiscardDraft) {
        Image(systemName: "xmark")
          .font(.system(size: 17, weight: .semibold))
          .frame(width: 44, height: 44)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(isProcessing)
      .accessibilityLabel("Discard Card")
    }
  }
}

/// Inline text editor or compact preview for the one card being composed.
private struct CreationComposerDraftContent: View {

  @Bindable var draft: ThreadDraftCard
  let isProcessing: Bool
  let onOpenDraft: @MainActor @Sendable () -> Void

  var body: some View {
    switch draft.kind {
    case .text:
      TextField("Write a card", text: $draft.text, axis: .vertical)
        .textFieldStyle(.plain)
        .lineLimit(1...5)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .disabled(isProcessing)
        .accessibilityLabel("Card text")
    case .link, .file, .photo, .video, .livePhoto, .audio, .suggestion, .doodle, .bauhaus, .unknown:
      Button(action: onOpenDraft) {
        CreationComposerDraftPreview(draft: draft)
      }
      .buttonStyle(.plain)
      .disabled(isProcessing)
      .accessibilityLabel("Edit Card")
      .accessibilityValue(Text(draft.kind.displayTitle))
    @unknown default:
      Button(action: onOpenDraft) {
        CreationComposerDraftPreview(draft: draft)
      }
      .buttonStyle(.plain)
      .disabled(isProcessing)
      .accessibilityLabel("Edit Card")
      .accessibilityValue("Card")
    }
  }
}

/// Compact authored-content preview shown inside the input bar.
private struct CreationComposerDraftPreview: View {

  let draft: ThreadDraftCard

  var body: some View {
    HStack(spacing: 10) {
      CardPreviewContent(
        payload: draft.previewPayload,
        presentation: .draftSummary
      )
      .frame(width: 40, height: 40)
      .background(.background.opacity(0.72))
      .clipShape(.rect(cornerRadius: 10, style: .continuous))
      .allowsHitTesting(false)

      CreationComposerDraftLabel(kind: draft.kind)
    }
    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    .contentShape(Rectangle())
  }
}

/// Modality label shared by compact and expanded draft edit affordances.
private struct CreationComposerDraftLabel: View {

  let kind: Card.Kind

  var body: some View {
    HStack(spacing: 10) {
      Text(kind.displayTitle)
        .font(.body)
        .foregroundStyle(.primary)
        .lineLimit(1)

      Spacer(minLength: 0)

      Image(systemName: "chevron.right")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.tertiary)
    }
    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    .contentShape(Rectangle())
  }
}

/// Posts the current composer card while keeping progress in the same geometry.
private struct CreationComposerPostButton: View {

  @Environment(\.appPalette) private var palette

  let canPost: Bool
  let isProcessing: Bool
  let onPost: @MainActor @Sendable () -> Void

  var body: some View {
    Button(action: onPost) {
      ZStack {
        Circle()
          .fill(postButtonBackground)

        if isProcessing {
          ProgressView()
            .controlSize(.small)
            .tint(palette.onTint)
        } else {
          Image(systemName: "arrow.up")
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(.appOnTint)
        }
      }
      .frame(width: 44, height: 44)
    }
    .buttonStyle(.plain)
    .disabled(canPost == false || isProcessing)
    .accessibilityLabel("Post Card")
    .keyboardShortcut(.return, modifiers: .command)
  }

  private var postButtonBackground: Color {
    if canPost, isProcessing == false {
      return .accentColor
    }

    return .secondary.opacity(0.26)
  }
}

#Preview("Creation Composer Content States") {
  CreationComposerInputBarPreviewGallery()
}

#Preview("Creation Composer Expanded Visuals") {
  CreationComposerExpandedVisualsPreviewGallery()
}

#Preview("Creation Composer Link and Audio") {
  CreationComposerLinkAndAudioPreviewGallery()
}

/// Interactive gallery for comparing every composer content presentation.
///
/// The gallery renders the production input bar without opening a vault store.
/// Each row owns a separate draft so text editing in one example never mutates
/// another example's state.
@MainActor
private struct CreationComposerInputBarPreviewGallery: View {

  var body: some View {
    PrimaryContainer(accentColor: .default) {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 24) {
          CreationComposerInputBarPreviewRow(
            title: "Text · Empty",
            draft: CreationComposerInputBarPreviewFixtures.emptyText
          )
          CreationComposerInputBarPreviewRow(
            title: "Text · Short",
            draft: CreationComposerInputBarPreviewFixtures.shortText
          )
          CreationComposerInputBarPreviewRow(
            title: "Text · Multiline",
            draft: CreationComposerInputBarPreviewFixtures.multilineText
          )
          CreationComposerInputBarPreviewRow(
            title: "Link · Incomplete",
            draft: CreationComposerInputBarPreviewFixtures.incompleteLink
          )
          CreationComposerInputBarPreviewRow(
            title: "Link · Ready",
            draft: CreationComposerInputBarPreviewFixtures.link
          )
          CreationComposerInputBarPreviewRow(
            title: "Photo · Expanded",
            draft: CreationComposerInputBarPreviewFixtures.photo
          )
          CreationComposerInputBarPreviewRow(
            title: "Video · Expanded",
            draft: CreationComposerInputBarPreviewFixtures.video
          )
          CreationComposerInputBarPreviewRow(
            title: "Live Photo · Expanded",
            draft: CreationComposerInputBarPreviewFixtures.livePhoto
          )
          CreationComposerInputBarPreviewRow(
            title: "Audio · Wide",
            draft: CreationComposerInputBarPreviewFixtures.audio
          )
          CreationComposerInputBarPreviewRow(
            title: "Suggestion",
            draft: CreationComposerInputBarPreviewFixtures.suggestion
          )
          CreationComposerInputBarPreviewRow(
            title: "Doodle · Expanded",
            draft: CreationComposerInputBarPreviewFixtures.doodle
          )
          CreationComposerInputBarPreviewRow(
            title: "Bauhaus · Expanded",
            draft: CreationComposerInputBarPreviewFixtures.bauhaus
          )
          CreationComposerInputBarPreviewRow(
            title: "Unknown · Fallback",
            draft: CreationComposerInputBarPreviewFixtures.unknown
          )
          CreationComposerInputBarPreviewRow(
            title: "Posting",
            draft: CreationComposerInputBarPreviewFixtures.processing,
            isProcessing: true
          )
        }
        .padding(.vertical, 24)
      }
      .background(.background)
    }
  }
}

/// Focused Preview for square authored visuals.
@MainActor
private struct CreationComposerExpandedVisualsPreviewGallery: View {

  var body: some View {
    PrimaryContainer(accentColor: .default) {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 24) {
          CreationComposerInputBarPreviewRow(
            title: "Doodle · Expanded",
            draft: CreationComposerInputBarPreviewFixtures.doodle
          )
          CreationComposerInputBarPreviewRow(
            title: "Bauhaus · Expanded",
            draft: CreationComposerInputBarPreviewFixtures.bauhaus
          )
          CreationComposerInputBarPreviewRow(
            title: "Photo · Expanded",
            draft: CreationComposerInputBarPreviewFixtures.photo
          )
          CreationComposerInputBarPreviewRow(
            title: "Video · Expanded",
            draft: CreationComposerInputBarPreviewFixtures.video
          )
          CreationComposerInputBarPreviewRow(
            title: "Live Photo · Expanded",
            draft: CreationComposerInputBarPreviewFixtures.livePhoto
          )
        }
        .padding(.vertical, 24)
      }
      .background(.background)
    }
  }
}

/// Focused Preview for the two full-width composer surfaces.
@MainActor
private struct CreationComposerLinkAndAudioPreviewGallery: View {

  var body: some View {
    PrimaryContainer(accentColor: .default) {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 24) {
          CreationComposerInputBarPreviewRow(
            title: "Link · Expanded",
            draft: CreationComposerInputBarPreviewFixtures.link
          )
          CreationComposerInputBarPreviewRow(
            title: "Audio · Wide",
            draft: CreationComposerInputBarPreviewFixtures.audio
          )
        }
        .padding(.vertical, 24)
      }
      .background(.background)
    }
  }
}

/// One independently editable composer state in the Preview gallery.
@MainActor
private struct CreationComposerInputBarPreviewRow: View {

  private let title: String
  private let isProcessing: Bool
  @State private var draft: ThreadDraftCard

  init(
    title: String,
    draft: ThreadDraftCard,
    isProcessing: Bool = false
  ) {
    self.title = title
    self.isProcessing = isProcessing
    _draft = State(initialValue: draft)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(verbatim: title)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.appOnPrimaryContainer.opacity(0.68))
        .padding(.horizontal, 6)

      CreationComposerInputBar(
        draft: draft,
        isProcessing: isProcessing,
        onOpenDraft: {},
        onDiscardDraft: {},
        onPost: {}
      ) {
        Button(action: {}) {
          Label {
            Text(verbatim: "Preview action")
          } icon: {
            Image(systemName: "plus")
          }
        }
      }
    }
    .frame(maxWidth: CreationContainerMetrics.maximumComposerWidth)
    .frame(maxWidth: .infinity)
    .padding(.horizontal, CreationContainerMetrics.horizontalPadding)
  }
}

/// In-memory authored content used only by the composer Preview gallery.
@MainActor
private enum CreationComposerInputBarPreviewFixtures {

  static var emptyText: ThreadDraftCard {
    ThreadDraftCard()
  }

  static var shortText: ThreadDraftCard {
    ThreadDraftCard(text: "A small thought before it slips away.")
  }

  static var multilineText: ThreadDraftCard {
    ThreadDraftCard(
      text: "First line\nSecond line\nThird line\nFourth line\nFifth line"
    )
  }

  static var incompleteLink: ThreadDraftCard {
    let draft = ThreadDraftCard()
    draft.setLinkURLString("not a link yet")
    return draft
  }

  static var link: ThreadDraftCard {
    let draft = ThreadDraftCard()
    draft.setLinkURLString("https://tinycurve.app")
    return draft
  }

  static var photo: ThreadDraftCard {
    let draft = ThreadDraftCard()
    draft.setPhoto(
      CapturedPhoto(
        imageData: previewImageData,
        pixelSize: previewImageSize
      )
    )
    return draft
  }

  static var video: ThreadDraftCard {
    let draft = ThreadDraftCard()
    draft.setVideo(
      CapturedVideo(
        fileURL: missingVideoURL,
        thumbnailData: previewImageData,
        pixelSize: previewImageSize,
        duration: 12
      )
    )
    return draft
  }

  static var livePhoto: ThreadDraftCard {
    let draft = ThreadDraftCard()
    draft.setLivePhoto(
      CapturedLivePhoto(
        stillImageData: previewImageData,
        pairedVideoFileURL: missingVideoURL,
        thumbnailData: previewImageData,
        pixelSize: previewImageSize,
        duration: 2
      )
    )
    return draft
  }

  static var audio: ThreadDraftCard {
    let draft = ThreadDraftCard()
    draft.setAudio(
      AudioRecording(
        fileURL: missingAudioURL,
        duration: 42
      )
    )
    return draft
  }

  static var suggestion: ThreadDraftCard {
    let draft = ThreadDraftCard()
    draft.setSuggestion(
      SuggestionCardPayload(
        title: "A quiet morning",
        dateInterval: nil,
        elements: [
          .reflection(
            id: UUID(),
            prompt: "What felt meaningful today?"
          )
        ]
      )
    )
    return draft
  }

  static var doodle: ThreadDraftCard {
    let draft = ThreadDraftCard()
    draft.setDoodle(
      DoodleDrawing(
        strokes: [
          DoodleStroke(
            points: [
              DoodlePoint(x: 12, y: 70, time: 0, width: 8),
              DoodlePoint(x: 44, y: 18, time: 0.4, width: 6),
              DoodlePoint(x: 82, y: 72, time: 0.8, width: 8),
            ],
            width: 8
          )
        ],
        canvasSize: CGSize(width: 100, height: 100),
        duration: 0.8
      )
    )
    return draft
  }

  static var bauhaus: ThreadDraftCard {
    let draft = ThreadDraftCard()
    draft.setBauhaus(
      BauhausGridDocument(
        artwork: BauhausGridArtwork(
          tiles: [
            BauhausTile(shape: .circle, shapeSwatch: .slot1),
            BauhausTile(shape: .square, shapeSwatch: .slot5),
            BauhausTile(shape: .triangleBottomTrailing, shapeSwatch: .slot7),
          ]
        )
      )
    )
    return draft
  }

  static var unknown: ThreadDraftCard {
    ThreadDraftCard(kind: .unknown)
  }

  static var processing: ThreadDraftCard {
    ThreadDraftCard(text: "Posting this card…")
  }

  private static let previewImageSize = CGSize(width: 4, height: 4)

  private static let previewImageData = Data(
    base64Encoded:
      "iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAYAAACp8Z5+AAAAAXNSR0IArs4c6QAAADhlWElmTU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAAqACAAQAAAABAAAABKADAAQAAAABAAAABAAAAADmpNw4AAAAGklEQVQIHWMMcNvyX4PhOQMMszDoMqAAwgIAXXQGC8PGsPEAAAAASUVORK5CYII="
  ) ?? Data()

  private static let missingVideoURL = URL(
    fileURLWithPath: "/__journal_preview__/preview.mp4"
  )

  private static let missingAudioURL = URL(
    fileURLWithPath: "/__journal_preview__/preview.m4a"
  )
}

private extension CardEditDraft {

  /// Expanded surface used for the current authored payload, when needed.
  var expandedComposerPreviewLayout: CreationComposerExpandedPreviewLayout? {
    switch kind {
    case .link:
      return linkURL == nil ? nil : .link
    case .photo, .video, .livePhoto, .doodle, .bauhaus:
      return .square
    case .audio:
      return .audio
    case .text, .file, .suggestion, .unknown:
      return nil
    @unknown default:
      return nil
    }
  }
}
