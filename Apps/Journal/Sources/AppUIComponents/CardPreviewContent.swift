import CaptureBauhaus
import CaptureDoodle
import JournalVault
import MuColor
import SwiftUI
import UIKit

/// Renders the card-kind-specific content inside a Journal card.
///
/// `CardSurface` owns the paper chrome: shape, fill, ratio, and padding. This
/// view owns the inner preview for text, link, photo, audio, doodle, Bauhaus,
/// and unknown cards so draft summaries and saved-card surfaces stay visually
/// aligned without sharing persistence details.
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

/// Saved media reference used by card previews.
///
/// This strips attachment rows down to the fields needed for rendering, keeping
/// record IDs, byte counts, and persistence-only metadata out of the component.
public struct CardPreviewAttachment: Hashable, Sendable {
  public let kind: JournalVault.Attachment.Kind
  public let fileURL: URL
  public let pairedVideoFileURL: URL?
  public let thumbnailData: Data?

  public init(
    kind: JournalVault.Attachment.Kind,
    fileURL: URL,
    pairedVideoFileURL: URL? = nil,
    thumbnailData: Data?
  ) {
    self.kind = kind
    self.fileURL = fileURL
    self.pairedVideoFileURL = pairedVideoFileURL
    self.thumbnailData = thumbnailData
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
