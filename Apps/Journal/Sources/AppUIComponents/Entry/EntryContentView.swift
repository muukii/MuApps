import SwiftUI

/// Routes one authored entry content value to its content-specific view.
///
/// The router owns no visual decisions. Each leaf view receives its own concrete
/// style, so text, links, media, audio, and authored formats can evolve without a
/// shared card-shaped presentation contract.
public struct EntryContentView: View {

  /// An interaction emitted by rendered authored content.
  public enum Action: Sendable {
    /// Requests that the owner toggles the Todo completion state.
    case toggleTodoCompletion
  }

  /// Handles interactions emitted by this content renderer.
  public typealias ActionHandler = @MainActor (Action) -> Void

  /// Controls whether rendered content exposes an interaction to its owner.
  public enum Interaction {
    /// Renders content without an interaction affordance.
    case readOnly

    /// Renders supported interaction affordances and sends their actions to the
    /// owning feature.
    ///
    /// - Parameters:
    ///   - isEnabled: Whether mutation controls currently accept input.
    ///   - onAction: Handles an action emitted by the rendered content.
    case interactive(
      isEnabled: Bool = true,
      onAction: ActionHandler
    )
  }

  let content: EntryContent
  let style: EntryContentStyle
  let interaction: Interaction

  public init(
    content: EntryContent,
    style: EntryContentStyle = .cell,
    interaction: Interaction = .readOnly
  ) {
    self.content = content
    self.style = style
    self.interaction = interaction
  }

  public var body: some View {
    ZStack {
      switch content {
      case .text(let text):
        TextContentView(
          text: text,
          style: style.text
        )
      case .todo(let todo):
        TodoContentView(
          source: todo,
          style: style.todo,
          interaction: todoInteraction
        )
      case .link(let urlString):
        LinkContentView(urlString: urlString, style: style.link)
      case .file(let file):
        FileContentView(file: file, style: style.file)
      case .photo(let photo):
        PhotoContentView(photo: photo, style: style.photo)
      case .video(let video):
        VideoContentView(video: video, style: style.video)
      case .livePhoto(let livePhoto):
        LivePhotoContentView(livePhoto: livePhoto, style: style.livePhoto)
      case .audio(let audio):
        AudioContentView(audio: audio, style: style.audio)
      case .suggestion(let suggestion):
        SuggestionContentView(suggestion: suggestion, style: style.suggestion)
      case .doodle(let doodle):
        DoodleContentView(doodle: doodle, style: style.doodle)
      case .bauhaus(let bauhaus):
        BauhausContentView(bauhaus: bauhaus, style: style.bauhaus)
      case .unknown:
        UnknownContentView(style: style.unknown)
      }
    }
  }

  private var todoInteraction: TodoContentView.Interaction {
    switch interaction {
    case .readOnly:
      .readOnly
    case .interactive(let isEnabled, let onAction):
      .interactive(isEnabled: isEnabled) {
        onAction(.toggleTodoCompletion)
      }
    }
  }
}

/// A complete set of content-owned styles for one placement.
///
/// This public type selects a preset only. The concrete visual values live on
/// each leaf view's `Style`, keeping unrelated content formats independent.
public enum EntryContentStyle: Hashable, Sendable {
  /// Compact preview embedded in the entry composer.
  case composer

  /// Natural-height authored content used by every Home tree placement.
  case cell

  fileprivate var text: TextContentView.Style { .init(self) }
  fileprivate var todo: TodoContentView.Style { .init(self) }
  fileprivate var link: LinkContentView.Style { .init(self) }
  fileprivate var file: FileContentView.Style { .init(self) }
  fileprivate var photo: PhotoContentView.Style { .init(self) }
  fileprivate var video: VideoContentView.Style { .init(self) }
  fileprivate var livePhoto: LivePhotoContentView.Style { .init(self) }
  fileprivate var audio: AudioContentView.Style { .init(self) }
  fileprivate var suggestion: SuggestionContentView.Style { .init(self) }
  fileprivate var doodle: DoodleContentView.Style { .init(self) }
  fileprivate var bauhaus: BauhausContentView.Style { .init(self) }
  fileprivate var unknown: UnknownContentView.Style { .init(self) }
}

/// Persisted, draft, or export-ready authored content.
///
/// The value intentionally carries authored media values or file references,
/// not SwiftData models. Saved-entry readers and draft editors can build this
/// small value without leaking their storage boundary into the renderer.
public enum EntryContent: Equatable, Sendable {
  case text(String)
  case todo(TodoContentSource)
  case link(String)
  case file(FileContentSource)
  case photo(PhotoContentSource)
  case video(VideoContentSource)
  case livePhoto(LivePhotoContentSource)
  case audio(AudioContentSource)
  case suggestion(SuggestionContentSource)
  case doodle(DoodleContentSource)
  case bauhaus(BauhausContentSource)
  case unknown
}
