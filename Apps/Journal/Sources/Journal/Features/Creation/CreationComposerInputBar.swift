import AppUIComponents
import CaptureAudio
import CaptureBauhaus
import CaptureDoodle
import CapturePhoto
import Foundation
import JournalVault
import MuColor
import SwiftUI

/// Visual constants for the creation composer bar.
enum CreationContainerMetrics {

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

}

/// Visual dimensions used only by expanded input-bar previews.
private enum CreationComposerInputBarMetrics {

  /// Square visual length used by expanded authored-content previews.
  static let expandedSquarePreviewDimension: CGFloat = 220

  /// Shorter square length that leaves useful content visible in landscape.
  static let compactHeightSquarePreviewDimension: CGFloat = 160

  /// Height for native rich-link content inside an expanded composer.
  static let expandedLinkPreviewHeight: CGFloat = 160

  /// Landscape height for native rich-link content.
  static let compactHeightLinkPreviewHeight: CGFloat = 112

  /// Height for the wide ambient-audio waveform.
  static let expandedAudioPreviewHeight: CGFloat = 84

  /// Landscape height for the wide ambient-audio waveform.
  static let compactHeightAudioPreviewHeight: CGFloat = 72

}

/// Bottom composer bar that owns the visible state of one unpublished entry.
struct CreationComposerInputBar<MenuContent: View>: View {

  @Bindable private var draft: CardEditDraft
  private let placement: CreationComposerPlacement
  private let isPostDestinationAvailable: Bool
  private let focusRequestID: UUID?
  private let onConsumeFocusRequest: @MainActor @Sendable (UUID) -> Bool
  private let isProcessing: Bool
  private let onOpenDraft: @MainActor @Sendable () -> Void
  private let onDiscardDraft: @MainActor @Sendable () -> Void
  private let onToggleComposerMode: @MainActor @Sendable () -> Void
  private let onPost: @MainActor @Sendable () -> Void
  private let menuContent: MenuContent

  init(
    draft: CardEditDraft,
    placement: CreationComposerPlacement = .root,
    isPostDestinationAvailable: Bool = true,
    focusRequestID: UUID? = nil,
    onConsumeFocusRequest: @escaping @MainActor @Sendable (UUID) -> Bool = { _ in false },
    isProcessing: Bool,
    onOpenDraft: @escaping @MainActor @Sendable () -> Void,
    onDiscardDraft: @escaping @MainActor @Sendable () -> Void,
    onToggleComposerMode: @escaping @MainActor @Sendable () -> Void,
    onPost: @escaping @MainActor @Sendable () -> Void,
    @ViewBuilder menuContent: () -> MenuContent
  ) {
    self.draft = draft
    self.placement = placement
    self.isPostDestinationAvailable = isPostDestinationAvailable
    self.focusRequestID = focusRequestID
    self.onConsumeFocusRequest = onConsumeFocusRequest
    self.isProcessing = isProcessing
    self.onOpenDraft = onOpenDraft
    self.onDiscardDraft = onDiscardDraft
    self.onToggleComposerMode = onToggleComposerMode
    self.onPost = onPost
    self.menuContent = menuContent()
  }

  var body: some View {
    ZStack {
      if draft.usesExpandedComposerPreview {
        CreationComposerExpandedPreviewInputBar(
          draft: draft,
          placement: placement,
          isPostDestinationAvailable: isPostDestinationAvailable,
          isProcessing: isProcessing,
          onOpenDraft: onOpenDraft,
          onDiscardDraft: onDiscardDraft,
          onPost: onPost
        )
      } else {
        CreationComposerCompactInputBar(
          draft: draft,
          placement: placement,
          isPostDestinationAvailable: isPostDestinationAvailable,
          focusRequestID: focusRequestID,
          onConsumeFocusRequest: onConsumeFocusRequest,
          isProcessing: isProcessing,
          onOpenDraft: onOpenDraft,
          onDiscardDraft: onDiscardDraft,
          onToggleComposerMode: onToggleComposerMode,
          onPost: onPost
        ) {
          menuContent
        }
      }
    }
    .contentShape(Rectangle())
  }
}

/// One-line composer used by text and compact non-media content types.
private struct CreationComposerCompactInputBar<MenuContent: View>: View {

  @Bindable var draft: CardEditDraft
  let placement: CreationComposerPlacement
  let isPostDestinationAvailable: Bool
  let focusRequestID: UUID?
  let onConsumeFocusRequest: @MainActor @Sendable (UUID) -> Bool
  let isProcessing: Bool
  let onOpenDraft: @MainActor @Sendable () -> Void
  let onDiscardDraft: @MainActor @Sendable () -> Void
  let onToggleComposerMode: @MainActor @Sendable () -> Void
  let onPost: @MainActor @Sendable () -> Void
  let menuContent: MenuContent

  init(
    draft: CardEditDraft,
    placement: CreationComposerPlacement,
    isPostDestinationAvailable: Bool,
    focusRequestID: UUID?,
    onConsumeFocusRequest: @escaping @MainActor @Sendable (UUID) -> Bool,
    isProcessing: Bool,
    onOpenDraft: @escaping @MainActor @Sendable () -> Void,
    onDiscardDraft: @escaping @MainActor @Sendable () -> Void,
    onToggleComposerMode: @escaping @MainActor @Sendable () -> Void,
    onPost: @escaping @MainActor @Sendable () -> Void,
    @ViewBuilder menuContent: () -> MenuContent
  ) {
    self.draft = draft
    self.placement = placement
    self.isPostDestinationAvailable = isPostDestinationAvailable
    self.focusRequestID = focusRequestID
    self.onConsumeFocusRequest = onConsumeFocusRequest
    self.isProcessing = isProcessing
    self.onOpenDraft = onOpenDraft
    self.onDiscardDraft = onDiscardDraft
    self.onToggleComposerMode = onToggleComposerMode
    self.onPost = onPost
    self.menuContent = menuContent()
  }

  var body: some View {
    HStack(alignment: .bottom, spacing: 10) {
      CreationComposerLeadingAction(
        showsAddMenu: draft.isEmptyComposerDraft,
        isProcessing: isProcessing,
        onDiscardDraft: onDiscardDraft
      ) {
        menuContent
      }

      if let composerMode = draft.composerMode {
        CreationComposerTodoModeButton(
          mode: composerMode,
          isProcessing: isProcessing,
          onToggle: onToggleComposerMode
        )
      }

      CreationComposerDraftContent(
        draft: draft,
        placement: placement,
        focusRequestID: focusRequestID,
        onConsumeFocusRequest: onConsumeFocusRequest,
        isProcessing: isProcessing,
        onOpenDraft: onOpenDraft
      )

      CreationComposerPostButton(
        canPost: draft.canSave && isPostDestinationAvailable,
        placement: placement,
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

  @Environment(\.verticalSizeClass) private var verticalSizeClass

  let draft: CardEditDraft
  let placement: CreationComposerPlacement
  let isPostDestinationAvailable: Bool
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

      switch draft.composerPreviewInteraction {
      case .opensDetailEditor:
        Button(action: onOpenDraft) {
          CreationComposerExpandedPreviewCanvas {
            expandedContent
          }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .disabled(isProcessing)
        .accessibilityLabel("Edit Entry")
        .accessibilityValue(Text(draft.kind.displayTitle))
      case .playsInPlace:
        CreationComposerExpandedPreviewCanvas(isContentInteractive: true) {
          expandedContent
        }
        .frame(maxWidth: .infinity)
      case .inert:
        CreationComposerExpandedPreviewCanvas {
          expandedContent
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(draft.kind.displayTitle))
      }

      CreationComposerPostButton(
        canPost: draft.canSave && isPostDestinationAvailable,
        placement: placement,
        isProcessing: isProcessing,
        onPost: onPost
      )
    }
    .padding(6)
    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 29, style: .continuous))
  }

  @ViewBuilder
  private var expandedContent: some View {
    switch draft.kind {
    case .photo, .video, .livePhoto, .doodle, .bauhaus:
      EntryContentView(
        content: draft.entryContent,
        style: .composer
      )
      .aspectRatio(1, contentMode: .fit)
      .frame(maxWidth: squarePreviewDimension)
    case .link:
      EntryContentView(
        content: draft.entryContent,
        style: .composer
      )
      .frame(maxWidth: .infinity)
      .frame(height: linkPreviewHeight)
    case .audio, .text, .todo, .file, .suggestion, .unknown:
      EntryContentView(
        content: draft.entryContent,
        style: .composer
      )
    @unknown default:
      EntryContentView(
        content: draft.entryContent,
        style: .composer
      )
    }
  }

  private var squarePreviewDimension: CGFloat {
    if verticalSizeClass == .compact {
      return CreationComposerInputBarMetrics.compactHeightSquarePreviewDimension
    }

    return CreationComposerInputBarMetrics.expandedSquarePreviewDimension
  }

  private var linkPreviewHeight: CGFloat {
    if verticalSizeClass == .compact {
      return CreationComposerInputBarMetrics.compactHeightLinkPreviewHeight
    }

    return CreationComposerInputBarMetrics.expandedLinkPreviewHeight
  }

  private var audioPreviewHeight: CGFloat {
    if verticalSizeClass == .compact {
      return CreationComposerInputBarMetrics.compactHeightAudioPreviewHeight
    }

    return CreationComposerInputBarMetrics.expandedAudioPreviewHeight
  }
}

/// Shared clipping and accessibility treatment for an expanded preview.
private struct CreationComposerExpandedPreviewCanvas<Content: View>: View {

  /// Whether the rendered content owns controls operated in place, such as an
  /// audio transport. A flat preview stays inert so the surrounding affordance
  /// keeps the whole tap target and VoiceOver reads one element.
  let isContentInteractive: Bool
  let content: Content

  init(
    isContentInteractive: Bool = false,
    @ViewBuilder content: () -> Content
  ) {
    self.isContentInteractive = isContentInteractive
    self.content = content()
  }

  var body: some View {
    content
      .background(.background.opacity(0.72))
      .clipShape(.rect(cornerRadius: 23, style: .continuous))
      .allowsHitTesting(isContentInteractive)
      .accessibilityHidden(isContentInteractive == false)
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
      .accessibilityLabel("Add Content")
    } else {
      Button(action: onDiscardDraft) {
        Image(systemName: "xmark")
          .font(.system(size: 17, weight: .semibold))
          .frame(width: 44, height: 44)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(isProcessing)
      .accessibilityLabel("Discard Entry")
    }
  }
}

/// Persistent Text/Todo mode switch shown at the front of compact input.
private struct CreationComposerTodoModeButton: View {

  let mode: CreationComposerMode
  let isProcessing: Bool
  let onToggle: @MainActor @Sendable () -> Void

  var body: some View {
    Button(action: onToggle) {
      Image(systemName: "checkmark.circle")
        .font(.system(size: 24, weight: .regular))
        .foregroundStyle(
          mode == .todo ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary)
        )
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(isProcessing)
    .accessibilityLabel("Todo")
    .accessibilityValue(mode == .todo ? Text("On") : Text("Off"))
    .accessibilityAddTraits(mode == .todo ? .isSelected : [])
  }
}

/// Inline text editor or compact preview for the entry being composed.
private struct CreationComposerDraftContent: View {

  @Bindable var draft: CardEditDraft
  @FocusState private var focusedField: Field?
  let placement: CreationComposerPlacement
  let focusRequestID: UUID?
  let onConsumeFocusRequest: @MainActor @Sendable (UUID) -> Bool
  let isProcessing: Bool
  let onOpenDraft: @MainActor @Sendable () -> Void

  /// Inline editor that should receive one explicit Reply focus request.
  private enum Field: Hashable {
    case text
    case todo
  }

  var body: some View {
    switch draft.kind {
    case .text:
      TextField(placement.prompt, text: $draft.composerText, axis: .vertical)
        .textFieldStyle(.plain)
        .lineLimit(1...5)
        .focused($focusedField, equals: .text)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .disabled(isProcessing)
        .accessibilityLabel("Entry text")
        .task(id: focusRequestID) {
          await focusIfRequested(.text)
        }
    case .todo:
      TextField("Todo", text: $draft.text, axis: .vertical)
        .textFieldStyle(.plain)
        .lineLimit(1...5)
        .focused($focusedField, equals: .todo)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .disabled(isProcessing)
        .accessibilityLabel("Todo text")
        .task {
          await Task.yield()
          focusedField = .todo
        }
        .task(id: focusRequestID) {
          await focusIfRequested(.todo)
        }
    case .link, .file, .photo, .video, .livePhoto, .audio, .suggestion, .doodle, .bauhaus,
      .unknown:
      preview
    @unknown default:
      preview
    }
  }

  /// Compact previews never carry in-place controls: the 40pt thumbnail is too
  /// small to operate, and every kind that owns a transport is drawn expanded.
  @ViewBuilder
  private var preview: some View {
    switch draft.composerPreviewInteraction {
    case .opensDetailEditor:
      Button(action: onOpenDraft) {
        CreationComposerDraftPreview(draft: draft, showsDisclosure: true)
      }
      .buttonStyle(.plain)
      .disabled(isProcessing)
      .accessibilityLabel("Edit Entry")
      .accessibilityValue(Text(draft.kind.displayTitle))
    case .playsInPlace, .inert:
      CreationComposerDraftPreview(draft: draft, showsDisclosure: false)
    }
  }

  /// Accepts a request before suspension so structural reinsertion cannot run
  /// it twice, then yields once for the originating context menu to dismiss.
  private func focusIfRequested(_ field: Field) async {
    guard let focusRequestID,
      onConsumeFocusRequest(focusRequestID)
    else {
      return
    }
    await Task.yield()
    focusedField = field
  }
}

/// Compact authored-content preview shown inside the input bar.
private struct CreationComposerDraftPreview: View {

  let draft: CardEditDraft
  let showsDisclosure: Bool

  var body: some View {
    HStack(spacing: 10) {
      EntryContentView(
        content: draft.entryContent,
        style: .composer
      )
      .frame(width: 40, height: 40)
      .background(.background.opacity(0.72))
      .clipShape(.rect(cornerRadius: 10, style: .continuous))
      .allowsHitTesting(false)

      CreationComposerDraftLabel(
        kind: draft.kind,
        showsDisclosure: showsDisclosure
      )
    }
    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    .contentShape(Rectangle())
  }
}

/// Modality label for a compact draft preview.
private struct CreationComposerDraftLabel: View {

  let kind: Card.Kind

  /// Drawn only when tapping the preview actually opens a detail editor, so the
  /// chevron never promises an editor that does not exist.
  let showsDisclosure: Bool

  var body: some View {
    HStack(spacing: 10) {
      Text(kind.displayTitle)
        .font(.body)
        .foregroundStyle(.primary)
        .lineLimit(1)

      Spacer(minLength: 0)

      if showsDisclosure {
        Image(systemName: "chevron.right")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.tertiary)
      }
    }
    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    .contentShape(Rectangle())
  }
}

/// Posts the current entry while keeping progress in the same geometry.
private struct CreationComposerPostButton: View {

  @Environment(\.appPalette) private var palette

  let canPost: Bool
  let placement: CreationComposerPlacement
  let isProcessing: Bool
  let onPost: @MainActor @Sendable () -> Void

  var body: some View {
    Button(action: onPost) {
      ZStack {
        Circle()
          .fill(.tint)
          .opacity(isProcessing ? 0.3 : 1)

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
    .accessibilityLabel(placement.postAccessibilityLabel)
    .keyboardShortcut(.return, modifiers: .command)
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

/// Interactive gallery for comparing every composer content style.
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
            title: "Todo · Empty Mode",
            draft: CreationComposerInputBarPreviewFixtures.emptyTodo
          )
          CreationComposerInputBarPreviewRow(
            title: "Todo · Ready",
            draft: CreationComposerInputBarPreviewFixtures.todo
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
  @State private var draft: CardEditDraft

  init(
    title: String,
    draft: CardEditDraft,
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
        onToggleComposerMode: {
          draft.toggleComposerMode()
        },
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

  static var emptyText: CardEditDraft {
    CardEditDraft()
  }

  static var shortText: CardEditDraft {
    CardEditDraft(text: "A small thought before it slips away.")
  }

  static var multilineText: CardEditDraft {
    CardEditDraft(
      text: "First line\nSecond line\nThird line\nFourth line\nFifth line"
    )
  }

  static var emptyTodo: CardEditDraft {
    CardEditDraft(kind: .todo)
  }

  static var todo: CardEditDraft {
    CardEditDraft(kind: .todo, text: "Capture another task after posting this one.")
  }

  static var incompleteLink: CardEditDraft {
    let draft = CardEditDraft()
    draft.setLinkURLString("not a link yet")
    return draft
  }

  static var link: CardEditDraft {
    let draft = CardEditDraft()
    draft.setLinkURLString("https://tinycurve.app")
    return draft
  }

  static var photo: CardEditDraft {
    let draft = CardEditDraft()
    draft.setPhoto(
      CapturedPhoto(
        imageData: previewImageData,
        pixelSize: previewImageSize
      )
    )
    return draft
  }

  static var video: CardEditDraft {
    let draft = CardEditDraft()
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

  static var livePhoto: CardEditDraft {
    let draft = CardEditDraft()
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

  static var audio: CardEditDraft {
    let draft = CardEditDraft()
    draft.setAudio(
      AudioRecording(
        fileURL: missingAudioURL,
        duration: 42
      )
    )
    return draft
  }

  static var suggestion: CardEditDraft {
    let draft = CardEditDraft()
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

  static var doodle: CardEditDraft {
    let draft = CardEditDraft()
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

  static var bauhaus: CardEditDraft {
    let draft = CardEditDraft()
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

  static var unknown: CardEditDraft {
    CardEditDraft(kind: .unknown)
  }

  static var processing: CardEditDraft {
    CardEditDraft(text: "Posting this entry…")
  }

  private static let previewImageSize = CGSize(width: 4, height: 4)

  private static let previewImageData =
    Data(
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

/// How a composer preview answers a touch.
private enum CreationComposerPreviewInteraction {
  /// Reopens the draft's detail editor.
  case opensDetailEditor
  /// Hands the touch to controls the rendered content already owns.
  case playsInPlace
  /// A flat rendering with nothing to operate.
  case inert
}

extension CardEditDraft {

  /// How this draft's composer preview answers a touch.
  ///
  /// Only canvas-authored artwork earns an editor: a doodle or a Bauhaus grid
  /// holds work worth revising stroke by stroke, while every other capture is
  /// one-shot and a mistake is corrected by discarding the draft and capturing
  /// again. Audio needs no editor but is still not flat — its preview draws a
  /// transport, so the recording can be heard before posting.
  fileprivate var composerPreviewInteraction: CreationComposerPreviewInteraction {
    switch kind {
    case .doodle, .bauhaus:
      return .opensDetailEditor
    case .audio:
      return .playsInPlace
    case .text, .todo, .link, .file, .photo, .video, .livePhoto, .suggestion, .unknown:
      return .inert
    @unknown default:
      return .inert
    }
  }

  /// Whether the current authored content needs more than the one-line composer.
  fileprivate var usesExpandedComposerPreview: Bool {
    switch kind {
    case .link:
      return linkURL != nil
    case .photo, .video, .livePhoto, .audio, .doodle, .bauhaus:
      return true
    case .text, .todo, .file, .suggestion, .unknown:
      return false
    @unknown default:
      return false
    }
  }
}
