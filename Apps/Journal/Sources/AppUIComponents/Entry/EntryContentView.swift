import JournalVault
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
        .frame(minHeight: style.text.minimumHeight)
      case .todo(let todo):
        TodoContentView(
          source: todo,
          style: style.todo,
          interaction: todoInteraction
        )
        .frame(minHeight: style.todo.minimumHeight)
      case .link(let urlString):
        LinkContentView(urlString: urlString, style: style.link)
          .frame(minHeight: style.link.minimumHeight)
      case .file(let file):
        FileContentView(file: file, style: style.file)
          .frame(minHeight: style.file.minimumHeight)
      case .photo(let photo):
        PhotoContentView(photo: photo, style: style.photo)
          .frame(minHeight: style.photo.minimumHeight)
      case .video(let video):
        VideoContentView(video: video, style: style.video)
          .frame(minHeight: style.video.minimumHeight)
      case .livePhoto(let livePhoto):
        LivePhotoContentView(livePhoto: livePhoto, style: style.livePhoto)
          .frame(minHeight: style.livePhoto.minimumHeight)
      case .audio(let audio):
        AudioContentView(audio: audio, style: style.audio)
      //          .frame(minHeight: style.audio.minimumHeight)
      case .suggestion(let suggestion):
        SuggestionContentView(suggestion: suggestion, style: style.suggestion)
          .frame(minHeight: style.suggestion.minimumHeight)
      case .doodle(let doodle):
        DoodleContentView(doodle: doodle, style: style.doodle)
          .frame(minHeight: style.doodle.minimumHeight)
      case .bauhaus(let bauhaus):
        BauhausContentView(bauhaus: bauhaus, style: style.bauhaus)
          .frame(minHeight: style.bauhaus.minimumHeight)
      case .unknown:
        UnknownContentView(style: style.unknown)
          .frame(minHeight: style.unknown.minimumHeight)
      }
    }
    .clipShape(.rect(cornerRadius: 24))
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

  public init(
    kind: JournalVault.Card.Kind,
    body: String,
    completedAt: Date? = nil,
    attachment: EntryContentAttachment?
  ) {
    switch kind {
    case .text:
      self = .text(body)
    case .todo:
      self = .todo(
        TodoContentSource(text: body, completedAt: completedAt)
      )
    case .link:
      self = .link(body)
    case .file:
      let fileAttachment = attachment?.kind == .file ? attachment : nil
      self = .file(
        FileContentSource(
          displayName: body,
          fileURL: fileAttachment?.fileURL,
          contentType: fileAttachment?.contentType,
          byteSize: fileAttachment?.byteSize
        )
      )
    case .photo:
      self = .photo(
        PhotoContentSource(
          fileURL: attachment?.kind == .photo ? attachment?.fileURL : nil,
          fileRevision: attachment?.kind == .photo
            ? attachment?.fileRevision ?? 0 : 0,
          thumbnailData: attachment?.kind == .photo
            ? attachment?.thumbnailData : nil,
          pixelSize: attachment?.kind == .photo
            ? attachment?.pixelSize : nil
        )
      )
    case .video:
      self = .video(
        VideoContentSource(
          fileURL: attachment?.kind == .video ? attachment?.fileURL : nil,
          fileRevision: attachment?.kind == .video
            ? attachment?.fileRevision ?? 0 : 0,
          thumbnailData: attachment?.kind == .video
            ? attachment?.thumbnailData : nil,
          pixelSize: attachment?.kind == .video
            ? attachment?.pixelSize : nil
        )
      )
    case .livePhoto:
      self = .livePhoto(
        LivePhotoContentSource(
          fileURL: attachment?.kind == .livePhoto ? attachment?.fileURL : nil,
          pairedVideoFileURL: attachment?.kind == .livePhoto
            ? attachment?.pairedVideoFileURL : nil,
          fileRevision: attachment?.kind == .livePhoto
            ? attachment?.fileRevision ?? 0 : 0,
          thumbnailData: attachment?.kind == .livePhoto
            ? attachment?.thumbnailData : nil,
          pixelSize: attachment?.kind == .livePhoto
            ? attachment?.pixelSize : nil
        )
      )
    case .audio:
      self = .audio(
        AudioContentSource(
          fileURL: attachment?.kind == .audio ? attachment?.fileURL : nil,
          waveformLevels: attachment?.kind == .audio
            ? attachment?.waveformLevels : nil
        )
      )
    case .suggestion:
      let suggestionMediaFileURLsByResourceID =
        attachment?.kind == .suggestion
        ? attachment?.suggestionMediaFileURLsByResourceID ?? [:]
        : [:]
      self = .suggestion(
        SuggestionContentSource(
          fileURL: attachment?.kind == .suggestion ? attachment?.fileURL : nil,
          fileRevision: attachment?.kind == .suggestion
            ? attachment?.fileRevision ?? 0 : 0,
          mediaFileURLsByResourceID: suggestionMediaFileURLsByResourceID
        )
      )
    case .doodle:
      self = .doodle(
        DoodleContentSource(
          fileURL: attachment?.kind == .doodle ? attachment?.fileURL : nil,
          fileRevision: attachment?.kind == .doodle
            ? attachment?.fileRevision ?? 0 : 0,
          thumbnailData: attachment?.kind == .doodle
            ? attachment?.thumbnailData : nil,
          pixelSize: attachment?.kind == .doodle
            ? attachment?.pixelSize : nil
        )
      )
    case .bauhaus:
      self = .bauhaus(
        BauhausContentSource(
          fileURL: attachment?.kind == .bauhaus ? attachment?.fileURL : nil,
          fileRevision: attachment?.kind == .bauhaus
            ? attachment?.fileRevision ?? 0 : 0,
          thumbnailData: attachment?.kind == .bauhaus
            ? attachment?.thumbnailData : nil
        )
      )
    case .unknown:
      self = .unknown
    @unknown default:
      self = .unknown
    }
  }
}

/// Saved file-backed attachment reference used by authored-content views.
///
/// This strips attachment rows down to the fields needed for rendering, keeping
/// record IDs and persistence-only metadata out of the component. Generic file
/// cards additionally retain their content type and byte count so the preview
/// can describe the attachment without opening it.
public struct EntryContentAttachment: Hashable, Sendable {
  public let kind: JournalVault.Attachment.Kind
  public let fileURL: URL
  public let pairedVideoFileURL: URL?
  public let fileRevision: Int
  public let thumbnailData: Data?
  public let pixelSize: CGSize?
  public let contentType: String?
  public let byteSize: Int?
  /// Validated, quantized audio levels ordered from recording start to end.
  public let waveformLevels: Data?
  public let suggestionMediaFileURLsByResourceID: [UUID: URL]

  public init(
    kind: JournalVault.Attachment.Kind,
    fileURL: URL,
    pairedVideoFileURL: URL? = nil,
    fileRevision: Int = 0,
    thumbnailData: Data?,
    pixelSize: CGSize? = nil,
    contentType: String? = nil,
    byteSize: Int? = nil,
    waveformLevels: Data? = nil,
    suggestionMediaFileURLsByResourceID: [UUID: URL] = [:]
  ) {
    self.kind = kind
    self.fileURL = fileURL
    self.pairedVideoFileURL = pairedVideoFileURL
    self.fileRevision = fileRevision
    self.thumbnailData = thumbnailData
    self.pixelSize = pixelSize
    self.contentType = contentType
    self.byteSize = byteSize
    self.waveformLevels = waveformLevels
    self.suggestionMediaFileURLsByResourceID =
      suggestionMediaFileURLsByResourceID
  }
}
