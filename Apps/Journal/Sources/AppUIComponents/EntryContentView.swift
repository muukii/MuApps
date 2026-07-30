import AVFoundation
import CaptureBauhaus
import CaptureDoodle
import JournalVault
import MuColor
import SwiftUI
import UniformTypeIdentifiers

#if canImport(UIKit)
  import UIKit
#endif

/// Routes one authored entry content value to its content-specific view.
///
/// The router owns no visual decisions. Each leaf view receives its own concrete
/// style, so text, links, media, audio, and authored formats can evolve without a
/// shared card-shaped presentation contract.
public struct EntryContentView: View {

  let content: EntryContent
  let style: EntryContentStyle

  public init(
    content: EntryContent,
    style: EntryContentStyle
  ) {
    self.content = content
    self.style = style
  }

  public var body: some View {
    switch content {
    case .text(let text):
      TextContentView(
        text: text,
        style: style.text
      )
      .frame(minHeight: style.text.minimumHeight)
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
        .frame(minHeight: style.audio.minimumHeight)
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
}

/// A complete set of content-owned styles for one placement.
///
/// This public type selects a preset only. The concrete visual values live on
/// each leaf view's `Style`, keeping unrelated content formats independent.
public enum EntryContentStyle: Hashable, Sendable {
  case composer
  case savedGrid
  case detail
  case share

  fileprivate var text: TextContentView.Style { .init(self) }
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
    attachment: EntryContentAttachment?
  ) {
    switch kind {
    case .text:
      self = .text(body)
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
          fileURL: attachment?.kind == .audio ? attachment?.fileURL : nil
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
            ? attachment?.thumbnailData : nil
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

/// Suggestion preview source for either an unsaved draft or saved authored JSON.
public struct SuggestionContentSource: Equatable, Sendable {
  public let suggestion: SuggestionCardPayload?
  public let fileURL: URL?
  public let fileRevision: Int
  public let mediaFileURLsByResourceID: [UUID: URL]

  public init(
    suggestion: SuggestionCardPayload? = nil,
    fileURL: URL? = nil,
    fileRevision: Int = 0,
    mediaFileURLsByResourceID: [UUID: URL] = [:]
  ) {
    self.suggestion = suggestion
    self.fileURL = fileURL
    self.fileRevision = fileRevision
    self.mediaFileURLsByResourceID = mediaFileURLsByResourceID
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
    self.suggestionMediaFileURLsByResourceID =
      suggestionMediaFileURLsByResourceID
  }
}

/// Generic file values rendered by compact, detail, and export styles.
///
/// `displayName` comes from the card body, while `fileURL` points at the
/// primary `.file` attachment resource when it is locally available.
public struct FileContentSource: Hashable, Sendable {
  public let displayName: String
  public let fileURL: URL?
  public let contentType: String?
  public let byteSize: Int?

  public init(
    displayName: String,
    fileURL: URL? = nil,
    contentType: String? = nil,
    byteSize: Int? = nil
  ) {
    self.displayName = displayName
    self.fileURL = fileURL
    self.contentType = contentType
    self.byteSize = byteSize
  }
}

/// Photo preview source for either an unsaved draft or a saved card.
public struct PhotoContentSource: Equatable, Sendable {
  public let imageData: Data?
  public let fileURL: URL?
  public let fileRevision: Int
  public let thumbnailData: Data?
  public let displayAspectRatio: CGFloat?

  public init(
    imageData: Data? = nil,
    fileURL: URL? = nil,
    fileRevision: Int = 0,
    thumbnailData: Data? = nil,
    pixelSize: CGSize? = nil
  ) {
    self.imageData = imageData
    self.fileURL = fileURL
    self.fileRevision = fileRevision
    self.thumbnailData = thumbnailData
    self.displayAspectRatio = pixelSize?.contentAspectRatio
  }
}

/// Video preview source for either an unsaved draft or a saved card.
public struct VideoContentSource: Equatable, Sendable {
  public let fileURL: URL?
  public let fileRevision: Int
  public let thumbnailData: Data?
  public let displayAspectRatio: CGFloat?

  public init(
    fileURL: URL? = nil,
    fileRevision: Int = 0,
    thumbnailData: Data? = nil,
    pixelSize: CGSize? = nil
  ) {
    self.fileURL = fileURL
    self.fileRevision = fileRevision
    self.thumbnailData = thumbnailData
    self.displayAspectRatio = pixelSize?.contentAspectRatio
  }
}

/// Live Photo preview source for either an unsaved draft or a saved card.
public struct LivePhotoContentSource: Equatable, Sendable {
  public let stillImageData: Data?
  public let fileURL: URL?
  public let pairedVideoFileURL: URL?
  public let fileRevision: Int
  public let thumbnailData: Data?
  public let displayAspectRatio: CGFloat?

  public init(
    stillImageData: Data? = nil,
    fileURL: URL? = nil,
    pairedVideoFileURL: URL? = nil,
    fileRevision: Int = 0,
    thumbnailData: Data? = nil,
    pixelSize: CGSize? = nil
  ) {
    self.stillImageData = stillImageData
    self.fileURL = fileURL
    self.pairedVideoFileURL = pairedVideoFileURL
    self.fileRevision = fileRevision
    self.thumbnailData = thumbnailData
    self.displayAspectRatio = pixelSize?.contentAspectRatio
  }
}

/// Ambient-audio values needed by content rendering and export.
public struct AudioContentSource: Hashable, Sendable {
  public let fileURL: URL?

  public init(fileURL: URL? = nil) {
    self.fileURL = fileURL
  }
}

/// Doodle preview source for authored draft data or saved JSON media.
public struct DoodleContentSource: Equatable, Sendable {
  public let drawing: DoodleDrawing?
  public let fileURL: URL?
  public let fileRevision: Int
  public let thumbnailData: Data?

  public init(
    drawing: DoodleDrawing? = nil,
    fileURL: URL? = nil,
    fileRevision: Int = 0,
    thumbnailData: Data? = nil
  ) {
    self.drawing = drawing
    self.fileURL = fileURL
    self.fileRevision = fileRevision
    self.thumbnailData = thumbnailData
  }
}

/// Bauhaus preview source for authored draft data or saved JSON media.
public struct BauhausContentSource: Equatable, Sendable {
  public let document: BauhausGridDocument?
  public let fileURL: URL?
  public let fileRevision: Int
  public let thumbnailData: Data?

  public init(
    document: BauhausGridDocument? = nil,
    fileURL: URL? = nil,
    fileRevision: Int = 0,
    thumbnailData: Data? = nil
  ) {
    self.document = document
    self.fileURL = fileURL
    self.fileRevision = fileRevision
    self.thumbnailData = thumbnailData
  }
}

private struct TextContentView: View {

  /// Visual treatment owned by written content.
  struct Style {
    let preset: EntryContentStyle
    let emptyTitle: LocalizedStringResource

    init(
      _ preset: EntryContentStyle,
      emptyTitle: LocalizedStringResource? = nil
    ) {
      self.preset = preset
      self.emptyTitle = emptyTitle ?? Self.defaultEmptyTitle(for: preset)
    }

    var font: Font {
      switch preset {
      case .composer, .savedGrid, .detail:
        return .headline.weight(.semibold)
      case .share:
        return .system(size: 64, weight: .bold)
      }
    }

    var lineLimit: Int? {
      switch preset {
      case .composer, .savedGrid:
        return 8
      case .detail:
        return nil
      case .share:
        return 10
      }
    }

    private static func defaultEmptyTitle(
      for preset: EntryContentStyle
    ) -> LocalizedStringResource {
      switch preset {
      case .composer:
        return "Text"
      case .savedGrid, .detail:
        return "Empty text"
      case .share:
        return "Untitled"
      }
    }

    var lineSpacing: CGFloat {
      preset == .share ? 8 : 0
    }

    var minimumScaleFactor: CGFloat {
      preset == .share ? 0.62 : 1
    }

    var usesComposerForeground: Bool {
      preset == .composer
    }

    var fillsAvailableSpace: Bool {
      preset == .share
    }

    var minimumHeight: CGFloat? { nil }
  }

  let text: String
  let style: Style

  var body: some View {
    if text.isEmpty {
      if style.usesComposerForeground {
        Text(style.emptyTitle)
          .font(style.font)
          .lineLimit(style.lineLimit)
          .foregroundStyle(.secondary)
      } else {
        Text(style.emptyTitle)
          .font(style.font)
          .lineLimit(style.lineLimit)
          .lineSpacing(style.lineSpacing)
          .minimumScaleFactor(style.minimumScaleFactor)
          .frame(
            maxWidth: style.fillsAvailableSpace ? .infinity : nil,
            maxHeight: style.fillsAvailableSpace ? .infinity : nil,
            alignment: .topLeading
          )
      }
    } else {
      if style.usesComposerForeground {
        Text(text)
          .font(style.font)
          .lineLimit(style.lineLimit)
          .foregroundStyle(.primary)
      } else {
        Text(text)
          .font(style.font)
          .lineLimit(style.lineLimit)
          .lineSpacing(style.lineSpacing)
          .minimumScaleFactor(style.minimumScaleFactor)
          .frame(
            maxWidth: style.fillsAvailableSpace ? .infinity : nil,
            maxHeight: style.fillsAvailableSpace ? .infinity : nil,
            alignment: .topLeading
          )
      }
    }
  }
}

private struct LinkContentView: View {

  /// Visual and interaction treatment owned by link content.
  struct Style {
    let preset: EntryContentStyle

    init(_ preset: EntryContentStyle) {
      self.preset = preset
    }

    /// Finite native-preview height for placements that do not size the
    /// `LPLinkView` host themselves.
    ///
    /// The host intentionally has no intrinsic size because its native width
    /// can exceed a SwiftUI grid column. The saved-grid and detail styles must
    /// therefore provide the vertical proposal at their content boundary.
    var previewHeight: CGFloat? {
      switch preset {
      case .savedGrid:
        return 112
      case .detail:
        return 240
      case .composer, .share:
        return nil
      }
    }

    var allowsInteraction: Bool {
      preset == .detail
    }

    var fallbackTextStyle: TextContentView.Style {
      .init(
        preset,
        emptyTitle: preset == .composer ? "Link" : "Empty link"
      )
    }

    var minimumHeight: CGFloat? {
      previewHeight
    }
  }

  let urlString: String
  let style: Style

  var body: some View {
    if let linkURL = JournalLinkURL(urlString) {
      JournalLinkPreview(
        url: linkURL.url,
      )
      .frame(height: style.previewHeight)
      .allowsHitTesting(style.allowsInteraction)
    } else {
      TextContentView(
        text: urlString,
        style: style.fallbackTextStyle
      )
    }
  }
}

/// Generic-file treatment shared by saved tiles and detail rows.
///
/// The preview deliberately describes the persisted resource instead of trying
/// to decode arbitrary bytes. Opening or editing a generic file remains outside
/// this renderer's responsibility.
private struct FileContentView: View {

  /// Visual treatment owned by generic file content.
  struct Style {
    let preset: EntryContentStyle

    init(_ preset: EntryContentStyle) {
      self.preset = preset
    }

    var spacing: CGFloat {
      switch preset {
      case .composer, .savedGrid:
        return 10
      case .detail:
        return 14
      case .share:
        return 28
      }
    }

    var iconFont: Font {
      switch preset {
      case .composer, .savedGrid:
        return .system(size: 34, weight: .regular)
      case .detail:
        return .system(size: 52, weight: .regular)
      case .share:
        return .system(size: 112, weight: .regular)
      }
    }

    var titleFont: Font {
      switch preset {
      case .composer, .savedGrid, .detail:
        return .headline.weight(.semibold)
      case .share:
        return .system(size: 52, weight: .bold)
      }
    }

    var titleLineLimit: Int {
      switch preset {
      case .composer, .savedGrid:
        return 3
      case .detail, .share:
        return 4
      }
    }

    var metadataFont: Font {
      preset == .share ? .system(size: 26, weight: .medium) : .caption
    }

    var minimumScaleFactor: CGFloat {
      preset == .share ? 0.62 : 0.8
    }

    var padding: CGFloat {
      preset == .share ? 36 : 16
    }

    var showsUnavailableState: Bool {
      preset == .share
    }

    var fillsAvailableHeight: Bool {
      preset == .share
    }

    var minimumHeight: CGFloat? {
      preset == .detail ? 120 : nil
    }
  }

  let file: FileContentSource
  let style: Style

  var body: some View {
    VStack(spacing: style.spacing) {
      Image(systemName: "doc")
        .font(style.iconFont)
        .foregroundStyle(.secondary)

      Text(displayName)
        .font(style.titleFont)
        .lineLimit(style.titleLineLimit)
        .multilineTextAlignment(.center)
        .minimumScaleFactor(style.minimumScaleFactor)

      if metadata.isEmpty == false {
        Text(metadata.joined(separator: " · "))
          .font(style.metadataFont)
          .foregroundStyle(.secondary)
          .lineLimit(2)
          .multilineTextAlignment(.center)
      }

      if style.showsUnavailableState, file.fileURL == nil {
        Label("File unavailable", systemImage: "icloud.slash")
          .font(.system(size: 24, weight: .medium))
          .foregroundStyle(.secondary)
      }
    }
    .padding(style.padding)
    .frame(
      maxWidth: .infinity,
      maxHeight: style.fillsAvailableHeight ? .infinity : nil,
      alignment: .center
    )
    .accessibilityElement(children: .combine)
  }

  private var displayName: String {
    let name = file.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    if name.isEmpty == false {
      return name
    }

    if let fileURL = file.fileURL,
      fileURL.lastPathComponent.isEmpty == false
    {
      return fileURL.lastPathComponent
    }

    return String(localized: "File")
  }

  private var metadata: [String] {
    var values: [String] = []

    if let contentType = file.contentType,
      contentType.isEmpty == false
    {
      values.append(UTType(contentType)?.localizedDescription ?? contentType)
    }

    if let byteSize = file.byteSize {
      values.append(
        ByteCountFormatter.string(
          fromByteCount: Int64(byteSize),
          countStyle: .file
        )
      )
    }

    return values
  }
}

private struct SuggestionContentView: View {

  /// Visual treatment owned by Journaling Suggestion content.
  struct Style {
    let preset: EntryContentStyle

    init(_ preset: EntryContentStyle) {
      self.preset = preset
    }

    var additionalElementLimit: Int {
      switch preset {
      case .detail, .share:
        return .max
      case .composer, .savedGrid:
        return 2
      }
    }

    var mediaContentMode: ContentMode {
      switch preset {
      case .savedGrid, .detail, .share:
        return .fit
      case .composer:
        return .fill
      }
    }

    var titleFont: Font {
      preset == .share
        ? .system(size: 52, weight: .bold)
        : .title3.weight(.semibold)
    }

    var subtitleFont: Font {
      preset == .share ? .system(size: 26, weight: .medium) : .caption
    }

    var mediaAspectRatio: CGFloat { 1 }

    var showsFullTitle: Bool {
      preset == .detail || preset == .share
    }

    var contentPadding: CGFloat {
      preset == .share ? 36 : 16
    }

    var minimumHeight: CGFloat? {
      preset == .detail ? 120 : nil
    }
  }

  let suggestion: SuggestionContentSource
  let style: Style
  @State private var state: ContentMediaLoadState<SuggestionCardPayload> =
    .idle

  var body: some View {
    content
      .task(
        id: ContentFileLoadID(
          fileURL: suggestion.fileURL,
          fileRevision: suggestion.fileRevision
        )
      ) {
        await loadSuggestion()
      }
  }

  @ViewBuilder
  private var content: some View {
    let resolvedSuggestion = suggestion.suggestion ?? state.loadedPayload

    if let resolvedSuggestion {
      SuggestionContentHero(
        content: SuggestionDisplayContent(
          suggestion: resolvedSuggestion,
          mediaFileURLsByResourceID: suggestion.mediaFileURLsByResourceID,
          additionalElementLimit: style.additionalElementLimit
        ),
        style: style
      )
    } else if state.isLoading {
      SuggestionContentLoading(padding: style.contentPadding)
    } else {
      SuggestionContentPlaceholder(style: style)
    }
  }

  @MainActor
  private func loadSuggestion() async {
    guard suggestion.suggestion == nil else {
      state = .idle
      return
    }

    guard let fileURL = suggestion.fileURL else {
      state = .unavailable
      return
    }

    guard await ContentMediaFileReader.fileExists(at: fileURL) else {
      state = .unavailable
      return
    }

    state = .loading
    guard let data = await ContentMediaFileReader.data(from: fileURL),
      let payload = SuggestionCardPayload.decode(from: data),
      Task.isCancelled == false
    else {
      state = .unavailable
      return
    }

    state = .loaded(payload)
  }
}

private struct SuggestionContentHero: View {

  let content: SuggestionDisplayContent
  let style: SuggestionContentView.Style

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      SuggestionContentCategoryLabel(
        symbolName: content.primary.symbolName,
        title: content.primary.categoryTitle
      )

      if let imageFileURL = content.primary.imageFileURL {
        SuggestionContentMediaImage(
          fileURL: imageFileURL,
          imageStyle: content.primary.imageStyle,
          style: style
        )
      }

      SuggestionContentPrimaryText(
        content: content.primary,
        contextTitle: content.contextTitle,
        fallbackDate: content.fallbackDate,
        style: style
      )

      if content.additionalElements.isEmpty == false
        || content.hiddenElementCount > 0
      {
        SuggestionContentAdditionalElements(
          elements: content.additionalElements,
          hiddenElementCount: content.hiddenElementCount
        )
      }
    }
    .padding(style.contentPadding)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct SuggestionContentMediaImage: View {

  let fileURL: URL
  let imageStyle: SuggestionElementImageStyle
  let style: SuggestionContentView.Style
  @State private var image: UIImage?

  var body: some View {
    content
      .task(id: fileURL) {
        await loadImage()
      }
  }

  @ViewBuilder
  private var content: some View {
    switch imageStyle {
    case .media:
      if let image {

        Image(uiImage: image)
          .resizable()
          .aspectRatio(
            image.contentAspectRatio,
            contentMode: style.mediaContentMode
          )

      } else {
        ContentMediaPlaceholder(
          systemImage: "photo",
          aspectRatio: style.mediaAspectRatio
        )
      }

    case .icon:
      ZStack {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .fill(.appOnSecondaryContainer.opacity(0.08))

        if let image {
          Image(uiImage: image)
            .resizable()
            .scaledToFill()
        } else {
          Image(systemName: "photo")
            .font(.title3.weight(.semibold))
            .foregroundStyle(.appOnSecondaryContainer.opacity(0.42))
        }
      }
      .frame(width: 56, height: 56)
      .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
  }

  @MainActor
  private func loadImage() async {
    image = nil
    let loadedImage = await ContentMediaFileReader.image(at: fileURL)
    guard Task.isCancelled == false else {
      return
    }

    image = loadedImage
  }
}

private enum SuggestionElementImageStyle: Hashable {
  case media
  case icon
}

private struct SuggestionContentCategoryLabel: View {

  let symbolName: String
  let title: String

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: symbolName)
        .imageScale(.medium)

      Text(title)
        .lineLimit(1)
    }
    .font(.caption.weight(.semibold))
    .foregroundStyle(.appOnSecondaryContainer.opacity(0.66))
  }
}

private struct SuggestionContentPrimaryText: View {

  let content: SuggestionElementDisplayContent
  let contextTitle: String?
  let fallbackDate: Date?
  let style: SuggestionContentView.Style

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(content.title)
        .font(style.titleFont)
        .lineLimit(titleLineLimit)
        .foregroundStyle(.appOnSecondaryContainer)

      if let subtitle = content.subtitle {
        Text(subtitle)
          .font(style.subtitleFont.weight(.semibold))
          .lineLimit(2)
          .foregroundStyle(.appOnSecondaryContainer.opacity(0.72))
      }

      if let metadata = content.metadata {
        Text(metadata)
          .font(.caption.weight(.medium))
          .lineLimit(2)
          .foregroundStyle(.appOnSecondaryContainer.opacity(0.58))
      }

      if let contextTitle {
        Text(contextTitle)
          .font(.caption.weight(.medium))
          .lineLimit(1)
          .foregroundStyle(.appOnSecondaryContainer.opacity(0.48))
      }

      if let date = content.date ?? fallbackDate {
        Text(date, format: .dateTime.month().day().hour().minute())
          .font(.caption.weight(.medium))
          .lineLimit(1)
          .foregroundStyle(.appOnSecondaryContainer.opacity(0.58))
      }
    }
  }

  private var titleLineLimit: Int? {
    style.showsFullTitle ? nil : content.titleLineLimit
  }
}

private struct SuggestionContentAdditionalElements: View {

  let elements: [SuggestionElementDisplayContent]
  let hiddenElementCount: Int

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      ForEach(elements) { element in
        SuggestionElementPreviewRow(content: element)
      }

      if hiddenElementCount > 0 {
        Text("+ \(hiddenElementCount) more")
          .font(.caption.weight(.medium))
          .lineLimit(1)
          .foregroundStyle(.appOnSecondaryContainer.opacity(0.54))
      }
    }
  }
}

private struct SuggestionElementPreviewRow: View {

  let content: SuggestionElementDisplayContent

  var body: some View {
    Label {
      Text(content.compactSummary)
        .lineLimit(1)
    } icon: {
      Image(systemName: content.symbolName)
    }
    .font(.caption.weight(.medium))
    .foregroundStyle(.appOnSecondaryContainer.opacity(0.72))
  }
}

private struct SuggestionContentLoading: View {

  let padding: CGFloat

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      SuggestionContentCategoryLabel(
        symbolName: "sparkles",
        title: "Journaling Suggestion"
      )

      ProgressView()
        .controlSize(.small)
        .tint(.secondary)
    }
    .padding(padding)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct SuggestionContentPlaceholder: View {

  let style: SuggestionContentView.Style

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      SuggestionContentCategoryLabel(
        symbolName: "sparkles",
        title: "Journaling Suggestion"
      )

      Text("Suggestion")
        .font(style.titleFont)
        .foregroundStyle(.secondary)
    }
    .padding(style.contentPadding)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct SuggestionDisplayContent: Equatable {
  let primary: SuggestionElementDisplayContent
  let contextTitle: String?
  let fallbackDate: Date?
  let additionalElements: [SuggestionElementDisplayContent]
  let hiddenElementCount: Int

  init(
    suggestion: SuggestionCardPayload,
    mediaFileURLsByResourceID: [UUID: URL],
    additionalElementLimit: Int
  ) {
    let title = SuggestionText.cleaned(suggestion.title)
    let elementDisplays = suggestion.elements.map { element in
      element.displayContent(
        in: suggestion,
        mediaFileURLsByResourceID: mediaFileURLsByResourceID
      )
    }
    let primary =
      elementDisplays.first
      ?? .emptySuggestion(title: title, date: suggestion.dateInterval?.start)
    let additionalElements = Array(
      elementDisplays.dropFirst().prefix(additionalElementLimit)
    )

    self.primary = primary
    self.contextTitle = Self.contextTitle(title, primaryTitle: primary.title)
    self.fallbackDate = suggestion.dateInterval?.start
    self.additionalElements = additionalElements
    self.hiddenElementCount = max(
      0,
      elementDisplays.dropFirst().count - additionalElements.count
    )
  }

  private static func contextTitle(
    _ suggestionTitle: String?,
    primaryTitle: String
  ) -> String? {
    guard let suggestionTitle else {
      return nil
    }

    let normalizedSuggestionTitle = suggestionTitle.trimmingCharacters(
      in: .whitespacesAndNewlines
    ).lowercased()
    let normalizedPrimaryTitle = primaryTitle.trimmingCharacters(
      in: .whitespacesAndNewlines
    ).lowercased()

    return normalizedSuggestionTitle == normalizedPrimaryTitle
      ? nil : suggestionTitle
  }
}

private struct SuggestionElementDisplayContent: Identifiable, Equatable {
  let id: UUID
  let categoryTitle: String
  let symbolName: String
  let title: String
  let subtitle: String?
  let metadata: String?
  let date: Date?
  let titleLineLimit: Int
  let imageFileURL: URL?
  let imageStyle: SuggestionElementImageStyle

  init(
    id: UUID,
    categoryTitle: String,
    symbolName: String,
    title: String,
    subtitle: String?,
    metadata: String?,
    date: Date?,
    titleLineLimit: Int,
    imageFileURL: URL? = nil,
    imageStyle: SuggestionElementImageStyle = .media
  ) {
    self.id = id
    self.categoryTitle = categoryTitle
    self.symbolName = symbolName
    self.title = title
    self.subtitle = subtitle
    self.metadata = metadata
    self.date = date
    self.titleLineLimit = titleLineLimit
    self.imageFileURL = imageFileURL
    self.imageStyle = imageStyle
  }

  var compactSummary: String {
    SuggestionText.joined([title, subtitle, metadata]) ?? title
  }

  static func emptySuggestion(title: String?, date: Date?) -> Self {
    SuggestionElementDisplayContent(
      id: UUID(),
      categoryTitle: "Journaling Suggestion",
      symbolName: "sparkles",
      title: title ?? "Suggestion",
      subtitle: nil,
      metadata: nil,
      date: date,
      titleLineLimit: 3
    )
  }
}

private enum SuggestionText {

  static func cleaned(_ value: String?) -> String? {
    guard let value else {
      return nil
    }

    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  static func joined(_ parts: [String?]) -> String? {
    let values = parts.compactMap(cleaned)

    guard values.isEmpty == false else {
      return nil
    }

    return values.joined(separator: " - ")
  }
}

extension SuggestionCardElement {

  fileprivate func displayContent(
    in suggestion: SuggestionCardPayload,
    mediaFileURLsByResourceID: [UUID: URL]
  ) -> SuggestionElementDisplayContent {
    switch self {
    case .contact(let id, let name, _):
      return SuggestionElementDisplayContent(
        id: id,
        categoryTitle: "Contact",
        symbolName: symbolName,
        title: SuggestionText.cleaned(name) ?? "Contact",
        subtitle: nil,
        metadata: nil,
        date: nil,
        titleLineLimit: 2,
        imageFileURL: dominantImageFileURL(
          in: suggestion,
          mediaFileURLsByResourceID: mediaFileURLsByResourceID,
          preferredKinds: [.contactPhoto]
        ),
        imageStyle: .icon
      )

    case .eventPoster(
      let id,
      let title,
      _,
      let eventStart,
      _,
      let isHost,
      let placeName
    ):
      let cleanedTitle = SuggestionText.cleaned(title)
      let cleanedPlaceName = SuggestionText.cleaned(placeName)
      return SuggestionElementDisplayContent(
        id: id,
        categoryTitle: "Event",
        symbolName: symbolName,
        title: cleanedTitle ?? cleanedPlaceName ?? "Event",
        subtitle: cleanedTitle == nil ? nil : cleanedPlaceName,
        metadata: isHost == true ? "Hosting" : nil,
        date: eventStart,
        titleLineLimit: 2,
        imageFileURL: dominantImageFileURL(
          in: suggestion,
          mediaFileURLsByResourceID: mediaFileURLsByResourceID,
          preferredKinds: [.eventPosterImage]
        )
      )

    case .genericMedia(let id, let title, let artist, let album, let date, _):
      let cleanedTitle = SuggestionText.cleaned(title)
      let cleanedAlbum = SuggestionText.cleaned(album)
      return SuggestionElementDisplayContent(
        id: id,
        categoryTitle: "Media",
        symbolName: symbolName,
        title: cleanedTitle ?? cleanedAlbum ?? "Media",
        subtitle: SuggestionText.joined([
          artist, cleanedTitle == cleanedAlbum ? nil : cleanedAlbum,
        ]),
        metadata: nil,
        date: date,
        titleLineLimit: 2,
        imageFileURL: dominantImageFileURL(
          in: suggestion,
          mediaFileURLsByResourceID: mediaFileURLsByResourceID,
          preferredKinds: [.genericMediaAppIcon]
        ),
        imageStyle: .icon
      )

    case .livePhoto(let id, _, _, let date):
      return SuggestionElementDisplayContent(
        id: id,
        categoryTitle: "Live Photo",
        symbolName: symbolName,
        title: "Live Photo",
        subtitle: nil,
        metadata: nil,
        date: date,
        titleLineLimit: 2,
        imageFileURL: dominantImageFileURL(
          in: suggestion,
          mediaFileURLsByResourceID: mediaFileURLsByResourceID,
          preferredKinds: [.livePhotoImage]
        )
      )

    case .location(let id, let location):
      let place = SuggestionText.cleaned(location.place)
      let city = SuggestionText.cleaned(location.city)
      return SuggestionElementDisplayContent(
        id: id,
        categoryTitle: "Place",
        symbolName: symbolName,
        title: place ?? city ?? "Place",
        subtitle: place == nil || place == city ? nil : city,
        metadata: location.isWorkLocation == true ? "Work" : nil,
        date: location.date,
        titleLineLimit: 2
      )

    case .locationGroup(let id, let locations):
      let names = locations.compactMap {
        SuggestionText.joined([$0.place, $0.city])
      }
      let count = locations.count
      return SuggestionElementDisplayContent(
        id: id,
        categoryTitle: "Places",
        symbolName: symbolName,
        title: names.first ?? "\(count) places",
        subtitle: count > 1 ? "\(count) places" : nil,
        metadata: nil,
        date: locations.compactMap(\.date).min(),
        titleLineLimit: 2
      )

    case .motion(let id, let steps, let dateInterval, _, let movementType):
      return SuggestionElementDisplayContent(
        id: id,
        categoryTitle: "Motion",
        symbolName: symbolName,
        title: "\(steps) steps",
        subtitle: movementType?.displayTitle,
        metadata: dateInterval?.duration.formattedDuration,
        date: dateInterval?.start,
        titleLineLimit: 2,
        imageFileURL: dominantImageFileURL(
          in: suggestion,
          mediaFileURLsByResourceID: mediaFileURLsByResourceID,
          preferredKinds: [.motionIcon]
        ),
        imageStyle: .icon
      )

    case .photo(let id, _, let date):
      return SuggestionElementDisplayContent(
        id: id,
        categoryTitle: "Photo",
        symbolName: symbolName,
        title: "Photo",
        subtitle: nil,
        metadata: nil,
        date: date,
        titleLineLimit: 2,
        imageFileURL: dominantImageFileURL(
          in: suggestion,
          mediaFileURLsByResourceID: mediaFileURLsByResourceID,
          preferredKinds: [.photoImage]
        )
      )

    case .podcast(let id, let episode, let show, _, let date):
      let cleanedEpisode = SuggestionText.cleaned(episode)
      let cleanedShow = SuggestionText.cleaned(show)
      return SuggestionElementDisplayContent(
        id: id,
        categoryTitle: "Podcast",
        symbolName: symbolName,
        title: cleanedEpisode ?? cleanedShow ?? "Podcast",
        subtitle: cleanedEpisode == nil ? nil : cleanedShow,
        metadata: nil,
        date: date,
        titleLineLimit: 2,
        imageFileURL: dominantImageFileURL(
          in: suggestion,
          mediaFileURLsByResourceID: mediaFileURLsByResourceID,
          preferredKinds: [.podcastArtwork]
        )
      )

    case .reflection(let id, let prompt):
      return SuggestionElementDisplayContent(
        id: id,
        categoryTitle: "Reflection",
        symbolName: symbolName,
        title: SuggestionText.cleaned(prompt) ?? "Reflection",
        subtitle: nil,
        metadata: nil,
        date: nil,
        titleLineLimit: 4
      )

    case .song(let id, let title, let artist, let album, _, let date):
      let cleanedTitle = SuggestionText.cleaned(title)
      let cleanedAlbum = SuggestionText.cleaned(album)
      return SuggestionElementDisplayContent(
        id: id,
        categoryTitle: "Song",
        symbolName: symbolName,
        title: cleanedTitle ?? "Song",
        subtitle: SuggestionText.joined([
          artist, cleanedTitle == cleanedAlbum ? nil : cleanedAlbum,
        ]),
        metadata: nil,
        date: date,
        titleLineLimit: 2,
        imageFileURL: dominantImageFileURL(
          in: suggestion,
          mediaFileURLsByResourceID: mediaFileURLsByResourceID,
          preferredKinds: [.songArtwork]
        )
      )

    case .stateOfMind(let id, let value, _):
      return SuggestionElementDisplayContent(
        id: id,
        categoryTitle: "State of Mind",
        symbolName: symbolName,
        title: value.displayTitle,
        subtitle:
          "Valence \(value.valence.formatted(.number.precision(.fractionLength(2))))",
        metadata: value.displayMetadata,
        date: value.date,
        titleLineLimit: 2,
        imageFileURL: dominantImageFileURL(
          in: suggestion,
          mediaFileURLsByResourceID: mediaFileURLsByResourceID,
          preferredKinds: [.stateOfMindIcon]
        ),
        imageStyle: .icon
      )

    case .video(let id, _, let date):
      return SuggestionElementDisplayContent(
        id: id,
        categoryTitle: "Video",
        symbolName: symbolName,
        title: "Video",
        subtitle: nil,
        metadata: nil,
        date: date,
        titleLineLimit: 2
      )

    case .workout(let id, let workout):
      return SuggestionElementDisplayContent(
        id: id,
        categoryTitle: "Workout",
        symbolName: symbolName,
        title: workout.displayTitle,
        subtitle: workout.displaySubtitle,
        metadata: workout.displayMetadata,
        date: workout.details?.dateInterval?.start,
        titleLineLimit: 2,
        imageFileURL: dominantImageFileURL(
          in: suggestion,
          mediaFileURLsByResourceID: mediaFileURLsByResourceID,
          preferredKinds: [.workoutIcon]
        ),
        imageStyle: .icon
      )

    case .workoutGroup(let id, let group):
      return SuggestionElementDisplayContent(
        id: id,
        categoryTitle: "Workouts",
        symbolName: symbolName,
        title: group.displayTitle,
        subtitle: group.displaySubtitle,
        metadata: group.displayMetadata,
        date: group.workouts.compactMap { $0.details?.dateInterval?.start }
          .min(),
        titleLineLimit: 2,
        imageFileURL: dominantImageFileURL(
          in: suggestion,
          mediaFileURLsByResourceID: mediaFileURLsByResourceID,
          preferredKinds: [.workoutGroupIcon]
        ),
        imageStyle: .icon
      )
    }
  }

  private func dominantImageFileURL(
    in suggestion: SuggestionCardPayload,
    mediaFileURLsByResourceID: [UUID: URL],
    preferredKinds: [SuggestionCardMediaResource.Kind]
  ) -> URL? {
    for kind in preferredKinds {
      if let media = suggestion.mediaResources.first(where: {
        $0.elementID == id && $0.kind == kind
      }) {
        if let resourceID = media.resourceID,
          let fileURL = mediaFileURLsByResourceID[resourceID],
          fileURL.isFileURL
        {
          return fileURL
        }

        if let fallbackURL = fallbackImageFileURL(for: kind) {
          return fallbackURL
        }
      }
    }

    for kind in preferredKinds {
      if let fallbackURL = fallbackImageFileURL(for: kind) {
        return fallbackURL
      }
    }

    return nil
  }

  private func fallbackImageFileURL(for kind: SuggestionCardMediaResource.Kind)
    -> URL?
  {
    let fileURL: URL?
    // Keep the payload pattern at the top level. Xcode Preview's design-time
    // rewriter can otherwise turn a nested tuple pattern into an expression.
    switch self {
    case .contact(_, _, let photoURL) where kind == .contactPhoto:
      fileURL = photoURL
    case .eventPoster(_, _, let imageURL, _, _, _, _)
      where kind == .eventPosterImage:
      fileURL = imageURL
    case .genericMedia(_, _, _, _, _, let appIconURL)
      where kind == .genericMediaAppIcon:
      fileURL = appIconURL
    case .livePhoto(_, let imageURL, _, _)
      where kind == .livePhotoImage:
      fileURL = imageURL
    case .motion(_, _, _, let iconURL, _)
      where kind == .motionIcon:
      fileURL = iconURL
    case .photo(_, let imageURL, _)
      where kind == .photoImage:
      fileURL = imageURL
    case .podcast(_, _, _, let artworkURL, _)
      where kind == .podcastArtwork:
      fileURL = artworkURL
    case .song(_, _, _, _, let artworkURL, _)
      where kind == .songArtwork:
      fileURL = artworkURL
    case .stateOfMind(_, _, let iconURL)
      where kind == .stateOfMindIcon:
      fileURL = iconURL
    case .workout(_, let workout)
      where kind == .workoutIcon:
      fileURL = workout.iconURL
    case .workoutGroup(_, let group)
      where kind == .workoutGroupIcon:
      fileURL = group.iconURL
    default:
      fileURL = nil
    }

    guard let fileURL, fileURL.isFileURL else {
      return nil
    }

    return fileURL
  }

  fileprivate var symbolName: String {
    switch self {
    case .contact:
      return "person.crop.circle"
    case .eventPoster:
      return "calendar.badge.clock"
    case .genericMedia:
      return "play.rectangle"
    case .livePhoto:
      return "livephoto"
    case .location:
      return "mappin.and.ellipse"
    case .locationGroup:
      return "map"
    case .motion:
      return "figure.walk"
    case .photo:
      return "photo"
    case .podcast:
      return "podcasts"
    case .reflection:
      return "quote.bubble"
    case .song:
      return "music.note"
    case .stateOfMind:
      return "heart.text.square"
    case .video:
      return "video"
    case .workout:
      return "figure.run"
    case .workoutGroup:
      return "figure.mixed.cardio"
    }
  }
}

extension SuggestionCardMotionMovement {

  fileprivate var displayTitle: String {
    switch self {
    case .running:
      return "Running"
    case .walking:
      return "Walking"
    case .runningWalking:
      return "Running and walking"
    }
  }
}

extension SuggestionCardStateOfMind {

  fileprivate var displayTitle: String {
    if valence >= 0.33 {
      return "Pleasant"
    } else if valence <= -0.33 {
      return "Unpleasant"
    } else {
      return "State of Mind"
    }
  }

  fileprivate var displayMetadata: String? {
    let values = [
      labelRawValues.isEmpty ? nil : "\(labelRawValues.count) labels",
      associationRawValues.isEmpty
        ? nil : "\(associationRawValues.count) associations",
    ]

    return SuggestionText.joined(values)
  }
}

extension SuggestionCardWorkout {

  fileprivate var displayTitle: String {
    SuggestionText.cleaned(details?.localizedName) ?? "Workout"
  }

  fileprivate var displaySubtitle: String? {
    SuggestionText.joined([
      details?.activeEnergyKilocalories.map(Self.kilocalorieText),
      details?.distanceMeters.map(Self.distanceText),
    ])
  }

  fileprivate var displayMetadata: String? {
    details?.averageHeartRateBeatsPerMinute.map(Self.heartRateText)
  }

  private static func kilocalorieText(_ value: Double) -> String {
    "\(Int(value.rounded())) kcal"
  }

  private static func distanceText(_ meters: Double) -> String {
    if meters < 1000 {
      return "\(Int(meters.rounded())) m"
    }

    return String(format: "%.1f km", meters / 1000)
  }

  private static func heartRateText(_ value: Double) -> String {
    "\(Int(value.rounded())) bpm"
  }
}

extension SuggestionCardWorkoutGroup {

  fileprivate var displayTitle: String {
    workouts.count == 1 ? "Workout" : "\(workouts.count) workouts"
  }

  fileprivate var displaySubtitle: String? {
    SuggestionText.joined([
      duration?.formattedDuration,
      activeEnergyKilocalories.map { "\(Int($0.rounded())) kcal" },
    ])
  }

  fileprivate var displayMetadata: String? {
    averageHeartRateBeatsPerMinute.map { "\(Int($0.rounded())) bpm" }
  }
}

extension TimeInterval {

  fileprivate var formattedDuration: String {
    let minutes = Int((self / 60).rounded())
    if minutes < 60 {
      return "\(minutes) min"
    }

    let hours = minutes / 60
    let remainingMinutes = minutes % 60
    return remainingMinutes == 0
      ? "\(hours) hr" : "\(hours) hr \(remainingMinutes) min"
  }
}

private struct PhotoContentView: View {

  /// Visual and loading treatment owned by still-photo content.
  struct Style {
    let preset: EntryContentStyle

    init(_ preset: EntryContentStyle) {
      self.preset = preset
    }

    var contentMode: ContentMode {
      switch preset {
      case .composer:
        return .fill
      case .savedGrid, .detail, .share:
        return .fit
      }
    }

    var isDetail: Bool { preset == .detail }
    var usesPrimaryData: Bool { preset == .composer || preset == .share }
    var placeholderAspectRatio: CGFloat { 1 }
    var minimumHeight: CGFloat? { isDetail ? 180 : nil }
  }

  let photo: PhotoContentSource
  let style: Style
  @State private var decodedImageDataImage: UIImage?
  @State private var decodedThumbnailImage: UIImage?
  @State private var loadedFullSizeImage: UIImage?

  @ViewBuilder
  var body: some View {
    switch style.preset {
    case .composer, .savedGrid, .detail:
      content
        .task(id: imageLoadID) {
          await refreshImages()
        }

    case .share:
      SynchronousImageContentView(
        imageData: photo.imageData ?? photo.thumbnailData,
        fallbackSystemImage: "photo"
      )
      .contentMediaWell(isEnabled: true)
    }
  }

  @ViewBuilder
  private var content: some View {
    if let image {
      Image(uiImage: image)
        .resizable()
        .aspectRatio(contentMode: .fill)
    } else {
      ContentMediaPlaceholder(
        systemImage: "photo",
        aspectRatio: style.placeholderAspectRatio
      )
      .detailMediaPlaceholderFrame(
        aspectRatio: photo.displayAspectRatio ?? 1,
        isDetail: style.isDetail
      )
    }
  }

  private var image: UIImage? {
    switch style.preset {
    case .composer, .share:
      return decodedImageDataImage
    case .savedGrid:
      return decodedThumbnailImage
    case .detail:
      return loadedFullSizeImage ?? decodedThumbnailImage
    }
  }

  private var imageLoadID: ContentImageLoadID {
    ContentImageLoadID(
      style: style.preset,
      fileURL: photo.fileURL,
      fileRevision: photo.fileRevision,
      primaryData: ContentImageDataFingerprint(photo.imageData),
      fallbackData: ContentImageDataFingerprint(photo.thumbnailData)
    )
  }

  private func displayAspectRatio(for image: UIImage) -> CGFloat {
    guard style.isDetail else {
      return image.contentAspectRatio
    }

    return photo.displayAspectRatio ?? image.contentAspectRatio
  }

  @MainActor
  private func refreshImages() async {
    decodedImageDataImage = nil
    decodedThumbnailImage = nil
    loadedFullSizeImage = nil

    switch style.preset {
    case .composer, .share:
      let image = await ContentMediaFileReader.image(from: photo.imageData)
      guard Task.isCancelled == false else {
        return
      }

      decodedImageDataImage = image

    case .savedGrid:
      let image = await ContentMediaFileReader.image(
        from: photo.thumbnailData
      )
      guard Task.isCancelled == false else {
        return
      }

      decodedThumbnailImage = image

    case .detail:
      let thumbnailImage = await ContentMediaFileReader.image(
        from: photo.thumbnailData
      )
      guard Task.isCancelled == false else {
        return
      }

      decodedThumbnailImage = thumbnailImage

      guard let fileURL = photo.fileURL else {
        return
      }

      let fullSizeImage = await ContentMediaFileReader.image(at: fileURL)
      guard Task.isCancelled == false else {
        return
      }

      loadedFullSizeImage = fullSizeImage
    }
  }
}

private struct VideoContentView: View {

  /// Visual and playback treatment owned by video content.
  struct Style {
    let preset: EntryContentStyle

    init(_ preset: EntryContentStyle) {
      self.preset = preset
    }

    var contentMode: ContentMode {
      switch preset {
      case .composer:
        return .fill
      case .savedGrid, .detail, .share:
        return .fill
      }
    }

    var videoGravity: AVLayerVideoGravity {
      switch preset {
      case .composer, .share:
        return .resizeAspectFill
      case .savedGrid, .detail:
        return .resizeAspectFill
      }
    }

    var isDetail: Bool { preset == .detail }
    var placeholderAspectRatio: CGFloat { 1 }
    var minimumHeight: CGFloat? { isDetail ? 180 : nil }
  }

  let video: VideoContentSource
  let style: Style
  @State private var thumbnailImage: UIImage?
  @State private var playableFileURL: URL?
  @State private var readyFileURL: URL?

  var body: some View {
    content
      .task(id: imageLoadID) {
        await refreshMedia()
      }
  }

  @ViewBuilder
  private var content: some View {
    if let fileURL = playableFileURL {
      playableVideo(fileURL)
    } else if let thumbnailImage {
      posterOnly(thumbnailImage)
    } else {
      ContentMediaPlaceholder(
        systemImage: "video",
        aspectRatio: style.placeholderAspectRatio
      )
      .detailMediaPlaceholderFrame(
        aspectRatio: video.displayAspectRatio ?? 16 / 9,
        isDetail: style.isDetail
      )
    }
  }

  private func playableVideo(_ fileURL: URL) -> some View {

    ZStack {
      Color.black.opacity(0.08)

      MutedLoopingVideoPlayer(
        fileURL: fileURL,
        videoGravity: .resizeAspectFill,
        onReadyForPlayback: {
          withAnimation(.easeInOut(duration: 0.18)) {
            readyFileURL = fileURL
          }
        }
      )

      if let thumbnailImage {
        Image(uiImage: thumbnailImage)
          .resizable()
          .aspectRatio(contentMode: style.contentMode)
          .opacity(readyFileURL == fileURL ? 0 : 1)
      }
    }

    .overlay(alignment: .bottomTrailing) {
      ContentMediaBadge(systemImage: "speaker.slash.fill")
    }
  }

  private func posterOnly(_ image: UIImage) -> some View {

    Image(uiImage: image)
      .resizable()
      .aspectRatio(
        style.isDetail
          ? video.displayAspectRatio ?? image.contentAspectRatio
          : image.contentAspectRatio,
        contentMode: style.contentMode
      )
      .overlay(alignment: .bottomTrailing) {
        ContentMediaBadge(systemImage: "play.fill")
      }
  }

  @MainActor
  private func refreshMedia() async {
    thumbnailImage = nil
    playableFileURL = nil
    readyFileURL = nil

    let image = await ContentMediaFileReader.image(
      from: video.thumbnailData
    )
    guard Task.isCancelled == false else {
      return
    }

    thumbnailImage = image

    guard let fileURL = video.fileURL else {
      return
    }

    let isPlayable = await ContentMediaFileReader.isPlayableMediaURL(
      fileURL
    )
    guard Task.isCancelled == false else {
      return
    }

    playableFileURL = isPlayable ? fileURL : nil
  }

  private var imageLoadID: ContentImageLoadID {
    ContentImageLoadID(
      style: style.preset,
      fileURL: video.fileURL,
      fileRevision: video.fileRevision,
      primaryData: ContentImageDataFingerprint(video.thumbnailData),
      fallbackData: nil
    )
  }

}

private struct LivePhotoContentView: View {

  /// Visual, loading, and playback treatment owned by Live Photo content.
  struct Style {
    let preset: EntryContentStyle

    init(_ preset: EntryContentStyle) {
      self.preset = preset
    }

    var contentMode: ContentMode {
      switch preset {
      case .composer:
        return .fill
      case .savedGrid, .detail, .share:
        return .fit
      }
    }

    var isDetail: Bool { preset == .detail }
    var usesPrimaryData: Bool { preset == .composer || preset == .share }
    var placeholderAspectRatio: CGFloat { 1 }
    var minimumHeight: CGFloat? { isDetail ? 180 : nil }
  }

  let livePhoto: LivePhotoContentSource
  let style: Style
  @State private var decodedStillImage: UIImage?
  @State private var decodedThumbnailImage: UIImage?
  @State private var loadedFullSizeImage: UIImage?
  @State private var isPairedVideoReady = false
  @GestureState private var isLivePhotoPlaybackActive = false

  var body: some View {
    content
      .task(id: imageLoadID) {
        await refreshImages()
      }
      .onChange(of: isLivePhotoPlaybackActive) { _, isActive in
        guard isActive == false else { return }
        isPairedVideoReady = false
      }
  }

  @ViewBuilder
  private var content: some View {
    if let image {

      sizedLivePhoto {
        ZStack {
          Image(uiImage: image)
            .resizable()
            .aspectRatio(contentMode: style.contentMode)

          if isLivePhotoPlaybackActive,
            let pairedVideoFileURL = livePhoto.pairedVideoFileURL
          {
            MutedLoopingVideoPlayer(
              fileURL: pairedVideoFileURL,
              videoGravity: style.isDetail
                ? .resizeAspect : .resizeAspectFill,
              onReadyForPlayback: {
                withAnimation(.easeInOut(duration: 0.16)) {
                  isPairedVideoReady = true
                }
              }
            )
            .opacity(isPairedVideoReady ? 1 : 0)
          }
        }
      }
      .contentShape(Rectangle())
      .gesture(
        livePhotoPlaybackGesture,
        isEnabled: style.isDetail
      )
      .overlay(alignment: .bottomTrailing) {
        ContentMediaBadge(systemImage: "livephoto")
      }
    } else {
      ContentMediaPlaceholder(
        systemImage: "livephoto",
        aspectRatio: style.placeholderAspectRatio
      )
      .detailMediaPlaceholderFrame(
        aspectRatio: livePhoto.displayAspectRatio ?? 1,
        isDetail: style.isDetail
      )
    }
  }

  private var livePhotoPlaybackGesture: some Gesture {
    LongPressGesture(minimumDuration: 0.32)
      .sequenced(before: DragGesture(minimumDistance: 0))
      .updating($isLivePhotoPlaybackActive) { value, state, _ in
        if case .second(true, _) = value {
          state = true
        }
      }
  }

  @ViewBuilder
  private func sizedLivePhoto<Content: View>(
    @ViewBuilder content: () -> Content
  ) -> some View {
    if style.isDetail {
      content()
        .aspectRatio(displayAspectRatio, contentMode: .fit)
    } else {
      content()
    }
  }

  private var image: UIImage? {
    switch style.preset {
    case .composer, .share:
      return decodedStillImage ?? decodedThumbnailImage
    case .savedGrid:
      return decodedThumbnailImage
    case .detail:
      return loadedFullSizeImage ?? decodedThumbnailImage
    }
  }

  private var imageLoadID: ContentImageLoadID {
    ContentImageLoadID(
      style: style.preset,
      fileURL: livePhoto.fileURL,
      fileRevision: livePhoto.fileRevision,
      primaryData: ContentImageDataFingerprint(livePhoto.stillImageData),
      fallbackData: ContentImageDataFingerprint(livePhoto.thumbnailData)
    )
  }

  private var displayAspectRatio: CGFloat {
    let decodedAspectRatio =
      decodedThumbnailImage?.contentAspectRatio
      ?? decodedStillImage?.contentAspectRatio
      ?? loadedFullSizeImage?.contentAspectRatio
      ?? 1
    guard style.isDetail else {
      return decodedAspectRatio
    }

    return livePhoto.displayAspectRatio ?? decodedAspectRatio
  }

  @MainActor
  private func refreshImages() async {
    decodedStillImage = nil
    decodedThumbnailImage = nil
    loadedFullSizeImage = nil

    switch style.preset {
    case .composer, .share:
      let stillImage = await ContentMediaFileReader.image(
        from: livePhoto.stillImageData
      )
      guard Task.isCancelled == false else {
        return
      }

      decodedStillImage = stillImage

      guard stillImage == nil else {
        return
      }

      let thumbnailImage = await ContentMediaFileReader.image(
        from: livePhoto.thumbnailData
      )
      guard Task.isCancelled == false else {
        return
      }

      decodedThumbnailImage = thumbnailImage

    case .savedGrid:
      let thumbnailImage = await ContentMediaFileReader.image(
        from: livePhoto.thumbnailData
      )
      guard Task.isCancelled == false else {
        return
      }

      decodedThumbnailImage = thumbnailImage

    case .detail:
      let thumbnailImage = await ContentMediaFileReader.image(
        from: livePhoto.thumbnailData
      )
      guard Task.isCancelled == false else {
        return
      }

      decodedThumbnailImage = thumbnailImage

      guard let fileURL = livePhoto.fileURL else {
        return
      }

      let fullSizeImage = await ContentMediaFileReader.image(at: fileURL)
      guard Task.isCancelled == false else {
        return
      }

      loadedFullSizeImage = fullSizeImage
    }
  }
}

private struct ContentMediaBadge: View {

  let systemImage: String

  var body: some View {
    Image(systemName: systemImage)
      .font(.caption.weight(.bold))
      .foregroundStyle(.white)
      .padding(8)
      .background(.black.opacity(0.48), in: Circle())
      .padding(8)
  }
}

private struct AudioContentView: View {

  /// Visual treatment owned by ambient-audio content.
  struct Style {
    let preset: EntryContentStyle

    init(_ preset: EntryContentStyle) {
      self.preset = preset
    }

    var samples: [AudioWaveformSample] {
      switch preset {
      case .composer:
        return AudioWaveformSample.composerSamples
      case .savedGrid, .detail:
        return AudioWaveformSample.savedSamples
      case .share:
        return AudioWaveformSample.shareSamples
      }
    }

    var barWidth: CGFloat { preset == .share ? 16 : 4 }
    var barSpacing: CGFloat { preset == .share ? 10 : 4 }
    var waveformOpacity: Double { preset == .share ? 0.44 : 0.62 }
    var minimumHeight: CGFloat? { preset == .detail ? 120 : nil }
  }

  let audio: AudioContentSource
  let style: Style

  @ViewBuilder
  var body: some View {
    switch style.preset {
    case .composer:
      waveform
        .frame(maxWidth: .infinity, minHeight: 68, alignment: .center)
    case .savedGrid, .detail:
      VStack(alignment: .leading, spacing: 14) {
        Label("Audio", systemImage: "waveform")
          .font(.headline.weight(.semibold))

        waveform
          .frame(
            maxWidth: .infinity,
            minHeight: 52,
            alignment: .center
          )
      }
    case .share:
      VStack(alignment: .leading, spacing: 36) {
        Image(systemName: "waveform")
          .font(.system(size: 96, weight: .semibold))

        waveform
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
  }

  private var waveform: some View {
    HStack(alignment: .center, spacing: style.barSpacing) {
      ForEach(style.samples) { sample in
        Capsule()
          .fill(
            .appOnSecondaryContainer.opacity(
              audio.fileURL == nil && style.preset == .share
                ? style.waveformOpacity / 2
                : style.waveformOpacity
            )
          )
          .frame(width: style.barWidth, height: sample.height)
      }
    }
  }
}

private struct AudioWaveformSample: Identifiable {
  let id: Int
  let height: CGFloat

  static let composerSamples: [AudioWaveformSample] = [
    18, 30, 24, 42, 34, 58, 46, 70, 38, 54, 28, 44,
  ].enumerated().map { index, height in
    AudioWaveformSample(id: index, height: CGFloat(height))
  }

  static let savedSamples: [AudioWaveformSample] = [
    18, 30, 24, 42, 34, 58, 46, 70, 38, 54, 28, 44, 64, 50, 36, 22,
  ].enumerated().map { index, height in
    AudioWaveformSample(id: index, height: CGFloat(height))
  }

  static let shareSamples: [AudioWaveformSample] = [
    61, 109, 80, 143, 101, 127, 72, 135, 93, 116,
  ].enumerated().map { index, height in
    AudioWaveformSample(id: index, height: CGFloat(height))
  }
}

private struct DoodleContentView: View {

  /// Visual treatment owned by vector doodle content.
  struct Style {
    let preset: EntryContentStyle

    init(_ preset: EntryContentStyle) {
      self.preset = preset
    }

    var displayAspectRatio: CGFloat? {
      switch preset {
      case .composer, .savedGrid:
        return 1
      case .detail, .share:
        return nil
      }
    }

    var artworkPadding: CGFloat {
      switch preset {
      case .composer, .detail:
        return 0
      case .savedGrid:
        return 10
      case .share:
        return 32
      }
    }

    var usesMediaWell: Bool { preset == .share }
    var usesCompactLoading: Bool { preset == .composer }
    var placeholderAspectRatio: CGFloat { 1 }
    var minimumHeight: CGFloat? { preset == .detail ? 180 : nil }
  }

  let doodle: DoodleContentSource
  let style: Style

  @Environment(\.appPalette) private var palette
  @State private var state: ContentMediaLoadState<DoodleDrawing> = .idle

  var body: some View {
    content
      .contentMediaWell(isEnabled: style.usesMediaWell)
      .task(
        id: ContentFileLoadID(
          fileURL: doodle.fileURL,
          fileRevision: doodle.fileRevision
        )
      ) {
        await loadDrawing()
      }
  }

  @ViewBuilder
  private var content: some View {
    if let drawing = doodle.drawing {
      rendered(drawing)
    } else {
      switch state {
      case .loaded(let drawing):
        rendered(drawing)
      case .loading:
        ContentLoadingMedia(isCompact: style.usesCompactLoading)
      case .idle, .unavailable:
        if style.preset == .share, doodle.thumbnailData != nil {
          SynchronousImageContentView(
            imageData: doodle.thumbnailData,
            fallbackSystemImage: "scribble"
          )
        } else {
          ContentMediaPlaceholder(
            systemImage: "scribble",
            aspectRatio: style.placeholderAspectRatio
          )
        }
      }
    }
  }

  @ViewBuilder
  private func rendered(_ drawing: DoodleDrawing) -> some View {
    DoodleDrawingView(
      drawing: drawing,
      inkColor: palette.tint,
      displayAspectRatio: style.displayAspectRatio
    )
    .padding(style.artworkPadding)
  }

  @MainActor
  private func loadDrawing() async {
    guard doodle.drawing == nil else {
      state = .idle
      return
    }

    guard let fileURL = doodle.fileURL else {
      state = .unavailable
      return
    }

    guard await ContentMediaFileReader.fileExists(at: fileURL) else {
      state = .unavailable
      return
    }

    state = .loading
    guard let data = await ContentMediaFileReader.data(from: fileURL),
      let drawing = try? JSONDecoder().decode(DoodleDrawing.self, from: data),
      Task.isCancelled == false
    else {
      state = .unavailable
      return
    }

    state = .loaded(drawing)
  }
}

private struct BauhausContentView: View {

  /// Visual treatment owned by Bauhaus artwork content.
  struct Style {
    let preset: EntryContentStyle

    init(_ preset: EntryContentStyle) {
      self.preset = preset
    }

    var artworkPadding: CGFloat {
      switch preset {
      case .composer, .detail:
        return 0
      case .savedGrid:
        return 8
      case .share:
        return 32
      }
    }

    var usesMediaWell: Bool { preset == .share }
    var usesCompactLoading: Bool { preset == .composer }
    var placeholderAspectRatio: CGFloat { 1 }
    var minimumHeight: CGFloat? { preset == .detail ? 180 : nil }
  }

  let bauhaus: BauhausContentSource
  let style: Style

  @State private var state: ContentMediaLoadState<BauhausGridDocument> =
    .idle

  var body: some View {
    content
      .contentMediaWell(isEnabled: style.usesMediaWell)
      .task(
        id: ContentFileLoadID(
          fileURL: bauhaus.fileURL,
          fileRevision: bauhaus.fileRevision
        )
      ) {
        await loadDocument()
      }
  }

  @ViewBuilder
  private var content: some View {
    if let document = bauhaus.document {
      rendered(document)
    } else {
      switch state {
      case .loaded(let document):
        rendered(document)
      case .loading:
        ContentLoadingMedia(isCompact: style.usesCompactLoading)
      case .idle, .unavailable:
        if style.preset == .share, bauhaus.thumbnailData != nil {
          SynchronousImageContentView(
            imageData: bauhaus.thumbnailData,
            fallbackSystemImage: "square.grid.3x3.square"
          )
        } else {
          ContentMediaPlaceholder(
            systemImage: "square.grid.3x3",
            aspectRatio: style.placeholderAspectRatio
          )
        }
      }
    }
  }

  @ViewBuilder
  private func rendered(_ document: BauhausGridDocument) -> some View {
    BauhausGridArtworkView(artwork: document.artwork)
      .padding(style.artworkPadding)
  }

  @MainActor
  private func loadDocument() async {
    guard bauhaus.document == nil else {
      state = .idle
      return
    }

    guard let fileURL = bauhaus.fileURL else {
      state = .unavailable
      return
    }

    guard await ContentMediaFileReader.fileExists(at: fileURL) else {
      state = .unavailable
      return
    }

    state = .loading
    guard let data = await ContentMediaFileReader.data(from: fileURL),
      let document = try? JSONDecoder().decode(
        BauhausGridDocument.self,
        from: data
      ),
      Task.isCancelled == false
    else {
      state = .unavailable
      return
    }

    state = .loaded(document)
  }
}

/// Loading state for authored media that may need to be decoded from disk.
private enum ContentMediaLoadState<Payload> {
  case idle
  case loading
  case loaded(Payload)
  case unavailable

  var loadedPayload: Payload? {
    guard case .loaded(let payload) = self else {
      return nil
    }

    return payload
  }

  var isLoading: Bool {
    if case .loading = self {
      return true
    }

    return false
  }
}

/// Stable identity for image decode tasks without hashing entire image data.
private struct ContentImageLoadID: Hashable {
  let style: EntryContentStyle
  let fileURL: URL?
  let fileRevision: Int
  let primaryData: ContentImageDataFingerprint?
  let fallbackData: ContentImageDataFingerprint?
}

private struct ContentFileLoadID: Hashable {
  let fileURL: URL?
  let fileRevision: Int
}

/// Lightweight fingerprint for image data used only to restart decode tasks.
private struct ContentImageDataFingerprint: Hashable, Sendable {
  let byteCount: Int
  let prefix: UInt64
  let suffix: UInt64

  init?(_ data: Data?) {
    guard let data else {
      return nil
    }

    byteCount = data.count
    prefix = Self.word(from: data.prefix(8))
    suffix = Self.word(from: data.suffix(8))
  }

  private static func word(from bytes: Data.SubSequence) -> UInt64 {
    bytes.reduce(UInt64(0)) { result, byte in
      (result << 8) | UInt64(byte)
    }
  }
}

private struct ContentLoadingMedia: View {

  let isCompact: Bool

  var body: some View {
    if isCompact {
      ProgressView()
        .controlSize(.small)
        .tint(.secondary)
    } else {
      ProgressView()
        .controlSize(.small)
        .tint(.secondary)
        .frame(maxWidth: .infinity)
        .aspectRatio(1, contentMode: .fit)
    }
  }
}

private struct ContentMediaPlaceholder: View {

  let systemImage: String
  let aspectRatio: CGFloat

  init(
    systemImage: String,
    aspectRatio: CGFloat = 1
  ) {
    self.systemImage = systemImage
    self.aspectRatio = aspectRatio
  }

  var body: some View {
    Image(systemName: systemImage)
      .font(.system(size: 34, weight: .semibold))
      .foregroundStyle(.appOnSecondaryContainer.opacity(0.42))
      .frame(maxWidth: .infinity)
      .aspectRatio(aspectRatio, contentMode: .fit)
  }
}

/// Synchronous image decoding used only by the one-shot export renderer.
///
/// Interactive app surfaces decode in cancellable tasks. Share rendering must
/// produce its complete first frame synchronously because `ImageRenderer` does
/// not wait for SwiftUI lifecycle tasks before capturing the canvas.
private struct SynchronousImageContentView: View {

  let imageData: Data?
  let fallbackSystemImage: String

  var body: some View {
    if let image = imageData.flatMap(UIImage.init(data:)) {
      Image(uiImage: image)
        .resizable()
        .scaledToFit()
        .padding(32)
    } else {
      Image(systemName: fallbackSystemImage)
        .font(.system(size: 108, weight: .semibold))
        .foregroundStyle(.appOnSecondaryContainer.opacity(0.42))
    }
  }
}

private struct UnknownContentView: View {

  /// Visual treatment owned by content from a newer, unrecognized app version.
  struct Style {
    let preset: EntryContentStyle

    init(_ preset: EntryContentStyle) {
      self.preset = preset
    }

    var minimumHeight: CGFloat? { preset == .detail ? 120 : nil }
  }

  let style: Style

  var body: some View {
    if style.preset == .composer {
      ContentMediaPlaceholder(
        systemImage: "questionmark.square.dashed",
        aspectRatio: 1
      )
    } else {
      ContentMediaPlaceholder(systemImage: "questionmark.square.dashed")
    }
  }
}

extension View {

  /// Reserves the eventual uncropped media geometry while a detail file loads.
  @ViewBuilder
  fileprivate func detailMediaPlaceholderFrame(
    aspectRatio: CGFloat,
    isDetail: Bool
  ) -> some View {
    if isDetail,
      aspectRatio.isFinite,
      aspectRatio > 0
    {
      frame(maxWidth: .infinity)
        .aspectRatio(aspectRatio, contentMode: .fit)
    } else {
      self
    }
  }

  /// Adds the export-only media well without making normal content card-shaped.
  @ViewBuilder
  fileprivate func contentMediaWell(isEnabled: Bool) -> some View {
    if isEnabled {
      ZStack {
        RoundedRectangle(cornerRadius: 32, style: .continuous)
          .fill(.appOnSecondaryContainer.opacity(0.06))

        self
      }
      .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
    } else {
      self
    }
  }
}

extension CGSize {

  /// Width divided by height when both persisted dimensions are usable.
  fileprivate var contentAspectRatio: CGFloat? {
    guard width.isFinite,
      height.isFinite,
      width > 0,
      height > 0
    else {
      return nil
    }

    return width / height
  }
}

extension UIImage {

  /// Best-effort display ratio for decoded thumbnails and original images.
  fileprivate var contentAspectRatio: CGFloat {
    size.contentAspectRatio ?? 1
  }
}

/// File-system reader used by preview views from SwiftUI lifecycle tasks.
private enum ContentMediaFileReader {
  nonisolated static func image(from data: Data?) async -> UIImage? {
    guard let data else {
      return nil
    }

    return await Task.detached(priority: .utility) {
      guard let image = UIImage(data: data) else {
        return nil
      }

      #if canImport(UIKit)
        if let preparedImage = await image.byPreparingForDisplay() {
          return preparedImage
        }
      #endif

      return image
    }.value
  }

  nonisolated static func image(at fileURL: URL) async -> UIImage? {
    await Task.detached(priority: .utility) {
      guard FileManager.default.fileExists(atPath: fileURL.path),
        let data = try? Data(contentsOf: fileURL),
        let image = UIImage(data: data)
      else {
        return nil
      }

      #if canImport(UIKit)
        if let preparedImage = await image.byPreparingForDisplay() {
          return preparedImage
        }
      #endif

      return image
    }.value
  }

  nonisolated static func fileExists(at fileURL: URL) async -> Bool {
    await Task.detached(priority: .utility) {
      FileManager.default.fileExists(atPath: fileURL.path)
    }.value
  }

  nonisolated static func isPlayableMediaURL(_ url: URL) async -> Bool {
    guard url.isFileURL else {
      return true
    }

    return await fileExists(at: url)
  }

  nonisolated static func data(from fileURL: URL) async -> Data? {
    await Task.detached(priority: .utility) {
      try? Data(contentsOf: fileURL)
    }.value
  }
}
