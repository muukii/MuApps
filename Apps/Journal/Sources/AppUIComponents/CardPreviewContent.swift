import CaptureBauhaus
import CaptureDoodle
import JournalVault
import MuColor
import SwiftUI
import UIKit

/// Renders the card-kind-specific content inside a Journal card.
///
/// `CardSurface` owns the paper chrome: shape, fill, ratio, and padding. This
/// view owns the inner preview for text, link, photo, audio, suggestion,
/// doodle, Bauhaus, and unknown cards so draft summaries and saved-card
/// surfaces stay visually aligned without sharing persistence details.
public struct CardPreviewContent: View {

  let payload: CardPreviewPayload
  let presentation: CardPreviewPresentation

  public init(
    payload: CardPreviewPayload,
    presentation: CardPreviewPresentation
  ) {
    self.payload = payload
    self.presentation = presentation
  }

  public var body: some View {
    switch payload {
    case .text(let text):
      CardPreviewText(
        text: text,
        emptyTitle: presentation.emptyTextTitle,
        presentation: presentation
      )
    case .link(let urlString):
      CardPreviewLink(urlString: urlString, presentation: presentation)
    case .photo(let photo):
      CardPreviewPhoto(photo: photo, presentation: presentation)
    case .video(let video):
      CardPreviewVideo(video: video, presentation: presentation)
    case .livePhoto(let livePhoto):
      CardPreviewLivePhoto(livePhoto: livePhoto, presentation: presentation)
    case .audio:
      CardPreviewAudio(presentation: presentation)
    case .suggestion(let suggestion):
      CardPreviewSuggestion(suggestion: suggestion, presentation: presentation)
    case .doodle(let doodle):
      CardPreviewDoodle(doodle: doodle, presentation: presentation)
    case .bauhaus(let bauhaus):
      CardPreviewBauhaus(bauhaus: bauhaus, presentation: presentation)
    case .unknown:
      CardPreviewUnknown(presentation: presentation)
    }
  }
}

/// Layout density for a card preview.
///
/// Draft summaries, saved grid tiles, and saved detail cards share rendering
/// primitives but not every metric. Keeping the mode explicit avoids boolean
/// flags whose meaning changes between text, media, and audio previews.
public enum CardPreviewPresentation: Hashable, Sendable {
  case draftSummary
  case savedSummary
  case savedDetail

  fileprivate var textFont: Font {
    switch self {
    case .savedDetail:
      return .title3.weight(.semibold)
    case .draftSummary, .savedSummary:
      return .headline.weight(.semibold)
    }
  }

  fileprivate var textLineLimit: Int? {
    switch self {
    case .savedDetail:
      return nil
    case .draftSummary, .savedSummary:
      return 8
    }
  }

  fileprivate var linkPreviewMode: JournalLinkPreview.Mode {
    switch self {
    case .savedDetail:
      return .detail
    case .draftSummary, .savedSummary:
      return .summary
    }
  }

  fileprivate var emptyTextTitle: LocalizedStringResource {
    switch self {
    case .draftSummary:
      return "Text"
    case .savedSummary, .savedDetail:
      return "Empty text card"
    }
  }

  fileprivate var emptyLinkTitle: LocalizedStringResource {
    switch self {
    case .draftSummary:
      return "Link"
    case .savedSummary, .savedDetail:
      return "Empty link card"
    }
  }

  fileprivate var photoAspectRatio: CGFloat {
    switch self {
    case .savedDetail:
      return 4 / 3
    case .draftSummary, .savedSummary:
      return 1
    }
  }

  fileprivate var savedMediaAspectRatio: CGFloat {
    switch self {
    case .savedDetail:
      return 4 / 3
    case .draftSummary, .savedSummary:
      return 1
    }
  }

  fileprivate var audioSamples: [CardPreviewAudioWaveformSample] {
    switch self {
    case .draftSummary:
      return CardPreviewAudioWaveformSample.draftSamples
    case .savedSummary, .savedDetail:
      return CardPreviewAudioWaveformSample.savedSamples
    }
  }
}

/// Persisted or draft payload that a `CardPreviewContent` can render.
///
/// The payload intentionally carries authored media values or file references,
/// not SwiftData models. Saved-entry readers and draft editors can build this
/// small value without leaking their storage boundary into the shared preview.
public enum CardPreviewPayload {
  case text(String)
  case link(String)
  case photo(CardPreviewPhotoPayload)
  case video(CardPreviewVideoPayload)
  case livePhoto(CardPreviewLivePhotoPayload)
  case audio
  case suggestion(CardPreviewSuggestionPayload)
  case doodle(CardPreviewDoodlePayload)
  case bauhaus(CardPreviewBauhausPayload)
  case unknown

  public init(
    kind: JournalVault.Card.Kind,
    body: String,
    attachment: CardPreviewAttachment?
  ) {
    switch kind {
    case .text:
      self = .text(body)
    case .link:
      self = .link(body)
    case .photo:
      self = .photo(
        CardPreviewPhotoPayload(
          fileURL: attachment?.kind == .photo ? attachment?.fileURL : nil,
          thumbnailData: attachment?.kind == .photo ? attachment?.thumbnailData : nil
        )
      )
    case .video:
      self = .video(
        CardPreviewVideoPayload(
          fileURL: attachment?.kind == .video ? attachment?.fileURL : nil,
          thumbnailData: attachment?.kind == .video ? attachment?.thumbnailData : nil
        )
      )
    case .livePhoto:
      self = .livePhoto(
        CardPreviewLivePhotoPayload(
          fileURL: attachment?.kind == .livePhoto ? attachment?.fileURL : nil,
          pairedVideoFileURL: attachment?.kind == .livePhoto ? attachment?.pairedVideoFileURL : nil,
          thumbnailData: attachment?.kind == .livePhoto ? attachment?.thumbnailData : nil
        )
      )
    case .audio:
      self = .audio
    case .suggestion:
      let suggestionMediaFileURLsByResourceID = attachment?.kind == .suggestion
        ? attachment?.suggestionMediaFileURLsByResourceID ?? [:]
        : [:]
      self = .suggestion(
        CardPreviewSuggestionPayload(
          fileURL: attachment?.kind == .suggestion ? attachment?.fileURL : nil,
          mediaFileURLsByResourceID: suggestionMediaFileURLsByResourceID
        )
      )
    case .doodle:
      self = .doodle(
        CardPreviewDoodlePayload(
          fileURL: attachment?.kind == .doodle ? attachment?.fileURL : nil
        )
      )
    case .bauhaus:
      self = .bauhaus(
        CardPreviewBauhausPayload(
          fileURL: attachment?.kind == .bauhaus ? attachment?.fileURL : nil
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
public struct CardPreviewSuggestionPayload {
  public let suggestion: SuggestionCardPayload?
  public let fileURL: URL?
  public let mediaFileURLsByResourceID: [UUID: URL]

  public init(
    suggestion: SuggestionCardPayload? = nil,
    fileURL: URL? = nil,
    mediaFileURLsByResourceID: [UUID: URL] = [:]
  ) {
    self.suggestion = suggestion
    self.fileURL = fileURL
    self.mediaFileURLsByResourceID = mediaFileURLsByResourceID
  }
}

/// Saved media reference used by card previews.
///
/// This strips attachment rows down to the fields needed for rendering, keeping
/// record IDs, byte counts, and persistence-only metadata out of the component.
public struct CardPreviewAttachment: Hashable, Sendable {
  public let kind: JournalVault.Attachment.Kind
  public let fileURL: URL
  public let pairedVideoFileURL: URL?
  public let thumbnailData: Data?
  public let suggestionMediaFileURLsByResourceID: [UUID: URL]

  public init(
    kind: JournalVault.Attachment.Kind,
    fileURL: URL,
    pairedVideoFileURL: URL? = nil,
    thumbnailData: Data?,
    suggestionMediaFileURLsByResourceID: [UUID: URL] = [:]
  ) {
    self.kind = kind
    self.fileURL = fileURL
    self.pairedVideoFileURL = pairedVideoFileURL
    self.thumbnailData = thumbnailData
    self.suggestionMediaFileURLsByResourceID = suggestionMediaFileURLsByResourceID
  }
}

/// Photo preview source for either an unsaved draft or a saved card.
public struct CardPreviewPhotoPayload {
  public let imageData: Data?
  public let fileURL: URL?
  public let thumbnailData: Data?

  public init(
    imageData: Data? = nil,
    fileURL: URL? = nil,
    thumbnailData: Data? = nil
  ) {
    self.imageData = imageData
    self.fileURL = fileURL
    self.thumbnailData = thumbnailData
  }
}

/// Video preview source for either an unsaved draft or a saved card.
public struct CardPreviewVideoPayload {
  public let fileURL: URL?
  public let thumbnailData: Data?

  public init(
    fileURL: URL? = nil,
    thumbnailData: Data? = nil
  ) {
    self.fileURL = fileURL
    self.thumbnailData = thumbnailData
  }
}

/// Live Photo preview source for either an unsaved draft or a saved card.
public struct CardPreviewLivePhotoPayload {
  public let stillImageData: Data?
  public let fileURL: URL?
  public let pairedVideoFileURL: URL?
  public let thumbnailData: Data?

  public init(
    stillImageData: Data? = nil,
    fileURL: URL? = nil,
    pairedVideoFileURL: URL? = nil,
    thumbnailData: Data? = nil
  ) {
    self.stillImageData = stillImageData
    self.fileURL = fileURL
    self.pairedVideoFileURL = pairedVideoFileURL
    self.thumbnailData = thumbnailData
  }
}

/// Doodle preview source for authored draft data or saved JSON media.
public struct CardPreviewDoodlePayload {
  public let drawing: DoodleDrawing?
  public let fileURL: URL?

  public init(
    drawing: DoodleDrawing? = nil,
    fileURL: URL? = nil
  ) {
    self.drawing = drawing
    self.fileURL = fileURL
  }
}

/// Bauhaus preview source for authored draft data or saved JSON media.
public struct CardPreviewBauhausPayload {
  public let document: BauhausGridDocument?
  public let fileURL: URL?

  public init(
    document: BauhausGridDocument? = nil,
    fileURL: URL? = nil
  ) {
    self.document = document
    self.fileURL = fileURL
  }
}

private struct CardPreviewText: View {

  let text: String
  let emptyTitle: LocalizedStringResource
  let presentation: CardPreviewPresentation

  var body: some View {
    if text.isEmpty {
      if presentation == .draftSummary {
        Text(emptyTitle)
          .font(presentation.textFont)
          .lineLimit(presentation.textLineLimit)
          .foregroundStyle(.secondary)
      } else {
        Text(emptyTitle)
          .font(presentation.textFont)
          .lineLimit(presentation.textLineLimit)
      }
    } else {
      if presentation == .draftSummary {
        Text(text)
          .font(presentation.textFont)
          .lineLimit(presentation.textLineLimit)
          .foregroundStyle(.primary)
      } else {
        Text(text)
          .font(presentation.textFont)
          .lineLimit(presentation.textLineLimit)
      }
    }
  }
}

private struct CardPreviewLink: View {

  let urlString: String
  let presentation: CardPreviewPresentation

  var body: some View {
    if let linkURL = JournalLinkURL(urlString) {
      JournalLinkPreview(
        url: linkURL.url,
        mode: presentation.linkPreviewMode
      )
    } else {
      CardPreviewText(
        text: urlString,
        emptyTitle: presentation.emptyLinkTitle,
        presentation: presentation
      )
    }
  }
}

private struct CardPreviewSuggestion: View {

  let suggestion: CardPreviewSuggestionPayload
  let presentation: CardPreviewPresentation
  @State private var state: CardPreviewMediaLoadState<SuggestionCardPayload> = .idle

  private var additionalElementLimit: Int {
    switch presentation {
    case .savedDetail:
      return Int.max
    case .draftSummary, .savedSummary:
      return 2
    }
  }

  var body: some View {
    content
      .task(id: suggestion.fileURL) {
        await loadSuggestion()
      }
  }

  @ViewBuilder
  private var content: some View {
    let resolvedSuggestion = suggestion.suggestion ?? state.loadedPayload

    if let resolvedSuggestion {
      SuggestionCardHero(
        content: SuggestionCardDisplayContent(
          suggestion: resolvedSuggestion,
          mediaFileURLsByResourceID: suggestion.mediaFileURLsByResourceID,
          additionalElementLimit: additionalElementLimit
        ),
        presentation: presentation
      )
    } else if state.isLoading {
      SuggestionCardLoading()
    } else {
      SuggestionCardPlaceholder(presentation: presentation)
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

    guard await CardPreviewMediaFileReader.fileExists(at: fileURL) else {
      state = .unavailable
      return
    }

    state = .loading
    guard let data = await CardPreviewMediaFileReader.data(from: fileURL),
          let payload = SuggestionCardPayload.decode(from: data),
          Task.isCancelled == false else {
      state = .unavailable
      return
    }

    state = .loaded(payload)
  }
}

private struct SuggestionCardHero: View {

  let content: SuggestionCardDisplayContent
  let presentation: CardPreviewPresentation

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      SuggestionCardCategoryLabel(
        symbolName: content.primary.symbolName,
        title: content.primary.categoryTitle
      )

      if let imageFileURL = content.primary.imageFileURL {
        SuggestionCardMediaImage(
          fileURL: imageFileURL,
          presentation: presentation
        )
      }

      SuggestionCardPrimaryText(
        content: content.primary,
        contextTitle: content.contextTitle,
        fallbackDate: content.fallbackDate,
        presentation: presentation
      )

      if content.additionalElements.isEmpty == false || content.hiddenElementCount > 0 {
        SuggestionCardAdditionalElements(
          elements: content.additionalElements,
          hiddenElementCount: content.hiddenElementCount
        )
      }
    }
    .padding(CardMetrics.padding)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct SuggestionCardMediaImage: View {

  let fileURL: URL
  let presentation: CardPreviewPresentation
  @State private var image: UIImage?

  var body: some View {
    content
      .task(id: fileURL) {
        await loadImage()
      }
  }

  @ViewBuilder
  private var content: some View {
    if let image {
      CardPreviewMediaBox(
        aspectRatio: presentation.suggestionMediaAspectRatio,
        showsBackground: false
      ) {
        Image(uiImage: image)
          .resizable()
          .scaledToFill()
      }
    } else {
      CardPreviewMediaPlaceholder(
        systemImage: "photo",
        aspectRatio: presentation.suggestionMediaAspectRatio
      )
    }
  }

  @MainActor
  private func loadImage() async {
    image = nil
    let loadedImage = await CardPreviewMediaFileReader.image(at: fileURL)
    guard Task.isCancelled == false else {
      return
    }

    image = loadedImage
  }
}

private struct SuggestionCardCategoryLabel: View {

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

private struct SuggestionCardPrimaryText: View {

  let content: SuggestionElementDisplayContent
  let contextTitle: String?
  let fallbackDate: Date?
  let presentation: CardPreviewPresentation

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(content.title)
        .font(presentation.suggestionTitleFont)
        .lineLimit(titleLineLimit)
        .foregroundStyle(.appOnSecondaryContainer)

      if let subtitle = content.subtitle {
        Text(subtitle)
          .font(presentation.suggestionSubtitleFont.weight(.semibold))
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
    switch presentation {
    case .savedDetail:
      return nil
    case .draftSummary, .savedSummary:
      return content.titleLineLimit
    }
  }
}

private struct SuggestionCardAdditionalElements: View {

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

private struct SuggestionCardLoading: View {

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      SuggestionCardCategoryLabel(symbolName: "sparkles", title: "Journaling Suggestion")

      ProgressView()
        .controlSize(.small)
        .tint(.secondary)
    }
    .padding(CardMetrics.padding)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct SuggestionCardPlaceholder: View {

  let presentation: CardPreviewPresentation

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      SuggestionCardCategoryLabel(symbolName: "sparkles", title: "Journaling Suggestion")

      Text("Suggestion")
        .font(presentation.suggestionTitleFont)
        .foregroundStyle(.secondary)
    }
    .padding(CardMetrics.padding)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct SuggestionCardDisplayContent: Equatable {
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
    let primary = elementDisplays.first ?? .emptySuggestion(title: title, date: suggestion.dateInterval?.start)
    let additionalElements = Array(elementDisplays.dropFirst().prefix(additionalElementLimit))

    self.primary = primary
    self.contextTitle = Self.contextTitle(title, primaryTitle: primary.title)
    self.fallbackDate = suggestion.dateInterval?.start
    self.additionalElements = additionalElements
    self.hiddenElementCount = max(0, elementDisplays.dropFirst().count - additionalElements.count)
  }

  private static func contextTitle(
    _ suggestionTitle: String?,
    primaryTitle: String
  ) -> String? {
    guard let suggestionTitle else {
      return nil
    }

    let normalizedSuggestionTitle = suggestionTitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let normalizedPrimaryTitle = primaryTitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

    return normalizedSuggestionTitle == normalizedPrimaryTitle ? nil : suggestionTitle
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

  init(
    id: UUID,
    categoryTitle: String,
    symbolName: String,
    title: String,
    subtitle: String?,
    metadata: String?,
    date: Date?,
    titleLineLimit: Int,
    imageFileURL: URL? = nil
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

private extension CardPreviewPresentation {

  var suggestionTitleFont: Font {
    switch self {
    case .savedDetail:
      return .title2.weight(.semibold)
    case .draftSummary, .savedSummary:
      return .title3.weight(.semibold)
    }
  }

  var suggestionSubtitleFont: Font {
    switch self {
    case .savedDetail:
      return .callout
    case .draftSummary, .savedSummary:
      return .caption
    }
  }

  var suggestionMediaAspectRatio: CGFloat {
    switch self {
    case .savedDetail:
      return 4 / 3
    case .draftSummary, .savedSummary:
      return 1
    }
  }
}

private extension SuggestionCardElement {

  func displayContent(
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
        )
      )

    case .eventPoster(let id, let title, _, let eventStart, _, let isHost, let placeName):
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
        subtitle: SuggestionText.joined([artist, cleanedTitle == cleanedAlbum ? nil : cleanedAlbum]),
        metadata: nil,
        date: date,
        titleLineLimit: 2
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
      let names = locations.compactMap { SuggestionText.joined([$0.place, $0.city]) }
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
        titleLineLimit: 2
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
        subtitle: SuggestionText.joined([artist, cleanedTitle == cleanedAlbum ? nil : cleanedAlbum]),
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
        subtitle: "Valence \(value.valence.formatted(.number.precision(.fractionLength(2))))",
        metadata: value.displayMetadata,
        date: value.date,
        titleLineLimit: 2
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
        titleLineLimit: 2
      )

    case .workoutGroup(let id, let group):
      return SuggestionElementDisplayContent(
        id: id,
        categoryTitle: "Workouts",
        symbolName: symbolName,
        title: group.displayTitle,
        subtitle: group.displaySubtitle,
        metadata: group.displayMetadata,
        date: group.workouts.compactMap { $0.details?.dateInterval?.start }.min(),
        titleLineLimit: 2
      )
    }
  }

  private func dominantImageFileURL(
    in suggestion: SuggestionCardPayload,
    mediaFileURLsByResourceID: [UUID: URL],
    preferredKinds: [SuggestionCardMediaResource.Kind]
  ) -> URL? {
    for kind in preferredKinds {
      if let media = suggestion.mediaResources.first(where: { $0.elementID == id && $0.kind == kind }) {
        if let resourceID = media.resourceID,
           let fileURL = mediaFileURLsByResourceID[resourceID],
           fileURL.isFileURL {
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

  private func fallbackImageFileURL(for kind: SuggestionCardMediaResource.Kind) -> URL? {
    let fileURL: URL?
    switch (kind, self) {
    case (.contactPhoto, .contact(_, _, let photoURL)):
      fileURL = photoURL
    case (.eventPosterImage, .eventPoster(_, _, let imageURL, _, _, _, _)):
      fileURL = imageURL
    case (.livePhotoImage, .livePhoto(_, let imageURL, _, _)):
      fileURL = imageURL
    case (.photoImage, .photo(_, let imageURL, _)):
      fileURL = imageURL
    case (.podcastArtwork, .podcast(_, _, _, let artworkURL, _)):
      fileURL = artworkURL
    case (.songArtwork, .song(_, _, _, _, let artworkURL, _)):
      fileURL = artworkURL
    default:
      fileURL = nil
    }

    guard let fileURL, fileURL.isFileURL else {
      return nil
    }

    return fileURL
  }

  var symbolName: String {
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

private extension SuggestionCardMotionMovement {

  var displayTitle: String {
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

private extension SuggestionCardStateOfMind {

  var displayTitle: String {
    if valence >= 0.33 {
      return "Pleasant"
    } else if valence <= -0.33 {
      return "Unpleasant"
    } else {
      return "State of Mind"
    }
  }

  var displayMetadata: String? {
    let values = [
      labelRawValues.isEmpty ? nil : "\(labelRawValues.count) labels",
      associationRawValues.isEmpty ? nil : "\(associationRawValues.count) associations",
    ]

    return SuggestionText.joined(values)
  }
}

private extension SuggestionCardWorkout {

  var displayTitle: String {
    SuggestionText.cleaned(details?.localizedName) ?? "Workout"
  }

  var displaySubtitle: String? {
    SuggestionText.joined([
      details?.activeEnergyKilocalories.map(Self.kilocalorieText),
      details?.distanceMeters.map(Self.distanceText),
    ])
  }

  var displayMetadata: String? {
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

private extension SuggestionCardWorkoutGroup {

  var displayTitle: String {
    workouts.count == 1 ? "Workout" : "\(workouts.count) workouts"
  }

  var displaySubtitle: String? {
    SuggestionText.joined([
      duration?.formattedDuration,
      activeEnergyKilocalories.map { "\(Int($0.rounded())) kcal" },
    ])
  }

  var displayMetadata: String? {
    averageHeartRateBeatsPerMinute.map { "\(Int($0.rounded())) bpm" }
  }
}

private extension TimeInterval {

  var formattedDuration: String {
    let minutes = Int((self / 60).rounded())
    if minutes < 60 {
      return "\(minutes) min"
    }

    let hours = minutes / 60
    let remainingMinutes = minutes % 60
    return remainingMinutes == 0 ? "\(hours) hr" : "\(hours) hr \(remainingMinutes) min"
  }
}

private struct CardPreviewPhoto: View {

  let photo: CardPreviewPhotoPayload
  let presentation: CardPreviewPresentation
  @State private var decodedImageDataImage: UIImage?
  @State private var decodedThumbnailImage: UIImage?
  @State private var loadedFullSizeImage: UIImage?

  var body: some View {
    content
      .task(id: imageLoadID) {
        await refreshImages()
      }
  }

  @ViewBuilder
  private var content: some View {
    if let image {
      CardPreviewMediaBox(
        aspectRatio: presentation.photoAspectRatio,
        showsBackground: false
      ) {
        Image(uiImage: image)
          .resizable()
          .scaledToFill()
      }
    } else {
      CardPreviewMediaPlaceholder(
        systemImage: "photo",
        aspectRatio: presentation.photoAspectRatio
      )
    }
  }

  private var image: UIImage? {
    switch presentation {
    case .draftSummary:
      return decodedImageDataImage
    case .savedSummary:
      return decodedThumbnailImage
    case .savedDetail:
      return loadedFullSizeImage ?? decodedThumbnailImage
    }
  }

  private var imageLoadID: CardPreviewImageLoadID {
    CardPreviewImageLoadID(
      presentation: presentation,
      fileURL: photo.fileURL,
      primaryData: CardPreviewImageDataFingerprint(photo.imageData),
      fallbackData: CardPreviewImageDataFingerprint(photo.thumbnailData)
    )
  }

  @MainActor
  private func refreshImages() async {
    decodedImageDataImage = nil
    decodedThumbnailImage = nil
    loadedFullSizeImage = nil

    switch presentation {
    case .draftSummary:
      let image = await CardPreviewMediaFileReader.image(from: photo.imageData)
      guard Task.isCancelled == false else {
        return
      }

      decodedImageDataImage = image

    case .savedSummary:
      let image = await CardPreviewMediaFileReader.image(from: photo.thumbnailData)
      guard Task.isCancelled == false else {
        return
      }

      decodedThumbnailImage = image

    case .savedDetail:
      let thumbnailImage = await CardPreviewMediaFileReader.image(from: photo.thumbnailData)
      guard Task.isCancelled == false else {
        return
      }

      decodedThumbnailImage = thumbnailImage

      guard let fileURL = photo.fileURL else {
        return
      }

      let fullSizeImage = await CardPreviewMediaFileReader.image(at: fileURL)
      guard Task.isCancelled == false else {
        return
      }

      loadedFullSizeImage = fullSizeImage
    }
  }
}

private struct CardPreviewVideo: View {

  let video: CardPreviewVideoPayload
  let presentation: CardPreviewPresentation
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
      CardPreviewMediaPlaceholder(
        systemImage: "video",
        aspectRatio: presentation.photoAspectRatio
      )
    }
  }

  private func playableVideo(_ fileURL: URL) -> some View {
    CardPreviewMediaBox(
      aspectRatio: presentation.photoAspectRatio,
      showsBackground: false
    ) {
      ZStack {
        Color.black.opacity(0.08)

        MutedLoopingVideoPlayer(
          fileURL: fileURL,
          onReadyForPlayback: {
            withAnimation(.easeInOut(duration: 0.18)) {
              readyFileURL = fileURL
            }
          }
        )

        if let thumbnailImage {
          Image(uiImage: thumbnailImage)
            .resizable()
            .scaledToFill()
            .opacity(readyFileURL == fileURL ? 0 : 1)
        }
      }
    }
    .overlay(alignment: .bottomTrailing) {
      CardPreviewMediaBadge(systemImage: "speaker.slash.fill")
    }
  }

  private func posterOnly(_ image: UIImage) -> some View {
    CardPreviewMediaBox(
      aspectRatio: presentation.photoAspectRatio,
      showsBackground: false
    ) {
      Image(uiImage: image)
        .resizable()
        .scaledToFill()
    }
    .overlay(alignment: .bottomTrailing) {
      CardPreviewMediaBadge(systemImage: "play.fill")
    }
  }

  @MainActor
  private func refreshMedia() async {
    thumbnailImage = nil
    playableFileURL = nil
    readyFileURL = nil

    let image = await CardPreviewMediaFileReader.image(from: video.thumbnailData)
    guard Task.isCancelled == false else {
      return
    }

    thumbnailImage = image

    guard let fileURL = video.fileURL else {
      return
    }

    let isPlayable = await CardPreviewMediaFileReader.isPlayableMediaURL(fileURL)
    guard Task.isCancelled == false else {
      return
    }

    playableFileURL = isPlayable ? fileURL : nil
  }

  private var imageLoadID: CardPreviewImageLoadID {
    CardPreviewImageLoadID(
      presentation: presentation,
      fileURL: video.fileURL,
      primaryData: CardPreviewImageDataFingerprint(video.thumbnailData),
      fallbackData: nil
    )
  }
}

private struct CardPreviewLivePhoto: View {

  let livePhoto: CardPreviewLivePhotoPayload
  let presentation: CardPreviewPresentation
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
      CardPreviewMediaBox(
        aspectRatio: presentation.photoAspectRatio,
        showsBackground: false
      ) {
        ZStack {
          Image(uiImage: image)
            .resizable()
            .scaledToFill()

          if isLivePhotoPlaybackActive, let pairedVideoFileURL = livePhoto.pairedVideoFileURL {
            MutedLoopingVideoPlayer(
              fileURL: pairedVideoFileURL,
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
      .gesture(livePhotoPlaybackGesture)
      .overlay(alignment: .bottomTrailing) {
        CardPreviewMediaBadge(systemImage: "livephoto")
      }
    } else {
      CardPreviewMediaPlaceholder(
        systemImage: "livephoto",
        aspectRatio: presentation.photoAspectRatio
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

  private var image: UIImage? {
    switch presentation {
    case .draftSummary:
      return decodedStillImage ?? decodedThumbnailImage
    case .savedSummary:
      return decodedThumbnailImage
    case .savedDetail:
      return loadedFullSizeImage ?? decodedThumbnailImage
    }
  }

  private var imageLoadID: CardPreviewImageLoadID {
    CardPreviewImageLoadID(
      presentation: presentation,
      fileURL: livePhoto.fileURL,
      primaryData: CardPreviewImageDataFingerprint(livePhoto.stillImageData),
      fallbackData: CardPreviewImageDataFingerprint(livePhoto.thumbnailData)
    )
  }

  @MainActor
  private func refreshImages() async {
    decodedStillImage = nil
    decodedThumbnailImage = nil
    loadedFullSizeImage = nil

    switch presentation {
    case .draftSummary:
      let stillImage = await CardPreviewMediaFileReader.image(from: livePhoto.stillImageData)
      guard Task.isCancelled == false else {
        return
      }

      decodedStillImage = stillImage

      guard stillImage == nil else {
        return
      }

      let thumbnailImage = await CardPreviewMediaFileReader.image(from: livePhoto.thumbnailData)
      guard Task.isCancelled == false else {
        return
      }

      decodedThumbnailImage = thumbnailImage

    case .savedSummary:
      let thumbnailImage = await CardPreviewMediaFileReader.image(from: livePhoto.thumbnailData)
      guard Task.isCancelled == false else {
        return
      }

      decodedThumbnailImage = thumbnailImage

    case .savedDetail:
      let thumbnailImage = await CardPreviewMediaFileReader.image(from: livePhoto.thumbnailData)
      guard Task.isCancelled == false else {
        return
      }

      decodedThumbnailImage = thumbnailImage

      guard let fileURL = livePhoto.fileURL else {
        return
      }

      let fullSizeImage = await CardPreviewMediaFileReader.image(at: fileURL)
      guard Task.isCancelled == false else {
        return
      }

      loadedFullSizeImage = fullSizeImage
    }
  }
}

private struct CardPreviewMediaBadge: View {

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

private struct CardPreviewAudio: View {

  let presentation: CardPreviewPresentation

  var body: some View {
    if presentation == .draftSummary {
      waveform
        .frame(maxWidth: .infinity, minHeight: 68, alignment: .center)
    } else {
      VStack(alignment: .leading, spacing: 14) {
        Label("Audio", systemImage: "waveform")
          .font(.headline.weight(.semibold))

        waveform
          .frame(maxWidth: .infinity, minHeight: presentation == .savedDetail ? 96 : 52, alignment: .center)
      }
    }
  }

  private var waveform: some View {
    HStack(alignment: .center, spacing: 4) {
      ForEach(presentation.audioSamples) { sample in
        Capsule()
          .fill(.appOnSecondaryContainer.opacity(0.62))
          .frame(width: 4, height: sample.height)
      }
    }
  }
}

private struct CardPreviewAudioWaveformSample: Identifiable {
  let id: Int
  let height: CGFloat

  static let draftSamples: [CardPreviewAudioWaveformSample] = [
    18, 30, 24, 42, 34, 58, 46, 70, 38, 54, 28, 44,
  ].enumerated().map { index, height in
    CardPreviewAudioWaveformSample(id: index, height: CGFloat(height))
  }

  static let savedSamples: [CardPreviewAudioWaveformSample] = [
    18, 30, 24, 42, 34, 58, 46, 70, 38, 54, 28, 44, 64, 50, 36, 22,
  ].enumerated().map { index, height in
    CardPreviewAudioWaveformSample(id: index, height: CGFloat(height))
  }
}

private struct CardPreviewDoodle: View {

  let doodle: CardPreviewDoodlePayload
  let presentation: CardPreviewPresentation

  @Environment(\.appPalette) private var palette
  @State private var state: CardPreviewMediaLoadState<DoodleDrawing> = .idle

  var body: some View {
    content
      .task(id: doodle.fileURL) {
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
        CardPreviewLoadingMedia(presentation: presentation)
      case .idle, .unavailable:
        CardPreviewMediaPlaceholder(
          systemImage: "scribble",
          aspectRatio: placeholderAspectRatio
        )
      }
    }
  }

  @ViewBuilder
  private func rendered(_ drawing: DoodleDrawing) -> some View {
    if presentation == .draftSummary {
      DoodleDrawingView(
        drawing: drawing,
        inkColor: palette.tint,
        displayAspectRatio: CardMetrics.aspectRatio
      )
    } else {
      CardPreviewRenderedMediaFrame(presentation: presentation) {
        DoodleDrawingView(
          drawing: drawing,
          inkColor: palette.tint,
          displayAspectRatio: presentation.savedMediaAspectRatio
        )
        .padding(presentation == .savedDetail ? 16 : 10)
      }
    }
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

    guard await CardPreviewMediaFileReader.fileExists(at: fileURL) else {
      state = .unavailable
      return
    }

    state = .loading
    guard let data = await CardPreviewMediaFileReader.data(from: fileURL),
          let drawing = try? JSONDecoder().decode(DoodleDrawing.self, from: data),
          Task.isCancelled == false else {
      state = .unavailable
      return
    }

    state = .loaded(drawing)
  }

  private var placeholderAspectRatio: CGFloat {
    switch presentation {
    case .draftSummary:
      return 1
    case .savedSummary, .savedDetail:
      return presentation.savedMediaAspectRatio
    }
  }
}

private struct CardPreviewBauhaus: View {

  let bauhaus: CardPreviewBauhausPayload
  let presentation: CardPreviewPresentation

  @State private var state: CardPreviewMediaLoadState<BauhausGridDocument> = .idle

  var body: some View {
    content
      .task(id: bauhaus.fileURL) {
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
        CardPreviewLoadingMedia(presentation: presentation)
      case .idle, .unavailable:
        CardPreviewMediaPlaceholder(
          systemImage: "square.grid.3x3",
          aspectRatio: placeholderAspectRatio
        )
      }
    }
  }

  @ViewBuilder
  private func rendered(_ document: BauhausGridDocument) -> some View {
    if presentation == .draftSummary {
      BauhausGridArtworkView(artwork: document.artwork)
    } else {
      CardPreviewRenderedMediaFrame(presentation: presentation) {
        BauhausGridArtworkView(artwork: document.artwork)
          .padding(presentation == .savedDetail ? 14 : 8)
      }
    }
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

    guard await CardPreviewMediaFileReader.fileExists(at: fileURL) else {
      state = .unavailable
      return
    }

    state = .loading
    guard let data = await CardPreviewMediaFileReader.data(from: fileURL),
          let document = try? JSONDecoder().decode(BauhausGridDocument.self, from: data),
          Task.isCancelled == false else {
      state = .unavailable
      return
    }

    state = .loaded(document)
  }

  private var placeholderAspectRatio: CGFloat {
    switch presentation {
    case .draftSummary:
      return 1
    case .savedSummary, .savedDetail:
      return presentation.savedMediaAspectRatio
    }
  }
}

/// Loading state for authored media that may need to be decoded from disk.
private enum CardPreviewMediaLoadState<Payload> {
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
private struct CardPreviewImageLoadID: Hashable {
  let presentation: CardPreviewPresentation
  let fileURL: URL?
  let primaryData: CardPreviewImageDataFingerprint?
  let fallbackData: CardPreviewImageDataFingerprint?
}

/// Lightweight fingerprint for image data used only to restart decode tasks.
private struct CardPreviewImageDataFingerprint: Hashable, Sendable {
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

private struct CardPreviewRenderedMediaFrame<Content: View>: View {

  let presentation: CardPreviewPresentation
  let content: Content

  init(
    presentation: CardPreviewPresentation,
    @ViewBuilder content: () -> Content
  ) {
    self.presentation = presentation
    self.content = content()
  }

  var body: some View {
    CardPreviewMediaBox(aspectRatio: presentation.savedMediaAspectRatio) {
      content
    }
  }
}

/// Fixed-aspect media container for card previews.
///
/// The box creates the layout size first, then clips any fill-mode content
/// inside that exact rectangle. This keeps photo and authored-media previews
/// from advertising an oversized layout or painting outside the card tile.
private struct CardPreviewMediaBox<Content: View>: View {

  let aspectRatio: CGFloat
  let showsBackground: Bool
  let content: Content

  init(
    aspectRatio: CGFloat,
    showsBackground: Bool = true,
    @ViewBuilder content: () -> Content
  ) {
    self.aspectRatio = aspectRatio
    self.showsBackground = showsBackground
    self.content = content()
  }

  var body: some View {
    RoundedRectangle(cornerRadius: 12, style: .continuous)
      .fill(.appOnSecondaryContainer.opacity(showsBackground ? 0.08 : 0))
      .aspectRatio(aspectRatio, contentMode: .fit)
      .overlay {
        GeometryReader { proxy in
          content
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .center)
            .clipped()
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
  }
}

private struct CardPreviewLoadingMedia: View {

  let presentation: CardPreviewPresentation

  var body: some View {
    if presentation == .draftSummary {
      ProgressView()
        .controlSize(.small)
        .tint(.secondary)
    } else {
      CardPreviewRenderedMediaFrame(presentation: presentation) {
        ProgressView()
          .controlSize(.small)
          .tint(.secondary)
      }
    }
  }
}

private struct CardPreviewMediaPlaceholder: View {

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
    CardPreviewMediaBox(aspectRatio: aspectRatio) {
      Image(systemName: systemImage)
        .font(.system(size: 34, weight: .semibold))
        .foregroundStyle(.appOnSecondaryContainer.opacity(0.42))
    }
  }
}

private struct CardPreviewUnknown: View {

  let presentation: CardPreviewPresentation

  var body: some View {
    if presentation == .draftSummary {
      CardPreviewMediaPlaceholder(
        systemImage: "questionmark.square.dashed",
        aspectRatio: 1
      )
    } else {
      CardPreviewMediaPlaceholder(systemImage: "questionmark.square.dashed")
    }
  }
}

/// File-system reader used by preview views from SwiftUI lifecycle tasks.
private enum CardPreviewMediaFileReader {
  nonisolated static func image(from data: Data?) async -> UIImage? {
    guard let data else {
      return nil
    }

    return await Task.detached(priority: .utility) {
      guard let image = UIImage(data: data) else {
        return nil
      }

      if let preparedImage = await image.byPreparingForDisplay() {
        return preparedImage
      }

      return image
    }.value
  }

  nonisolated static func image(at fileURL: URL) async -> UIImage? {
    await Task.detached(priority: .utility) {
      guard FileManager.default.fileExists(atPath: fileURL.path),
            let data = try? Data(contentsOf: fileURL),
            let image = UIImage(data: data) else {
        return nil
      }

      if let preparedImage = await image.byPreparingForDisplay() {
        return preparedImage
      }

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
