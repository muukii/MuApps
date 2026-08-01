import AVFoundation
import SwiftUI
#if canImport(UIKit)
  import UIKit
#endif

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
    self.displayAspectRatio =
      pixelSize?.contentAspectRatio
      ?? EncodedImageDimensions.displayAspectRatio(from: thumbnailData)
      ?? EncodedImageDimensions.displayAspectRatio(from: stillImageData)
  }
}

/// Renders a Live Photo still and its press-to-play paired video.
struct LivePhotoContentView: View {

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
      case .overview, .detail, .share:
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
      .detailMediaFrame(
        aspectRatio: displayAspectRatio,
        isDetail: style.isDetail
      )
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
        aspectRatio: displayAspectRatio
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
    switch style.preset {
    case .composer, .share:
      return decodedStillImage ?? decodedThumbnailImage
    case .overview:
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

  /// Keeps the placeholder, still, and paired-video states on one geometry.
  ///
  /// Persisted pixel dimensions describe the Live Photo before its still image
  /// decodes, so the detail placement can reserve its final box on the first
  /// layout pass instead of resizing once bytes arrive.
  private var displayAspectRatio: CGFloat {
    let decodedAspectRatio =
      decodedThumbnailImage?.contentAspectRatio
      ?? decodedStillImage?.contentAspectRatio
      ?? loadedFullSizeImage?.contentAspectRatio
    guard style.isDetail else {
      return decodedAspectRatio ?? style.placeholderAspectRatio
    }

    return
      livePhoto.displayAspectRatio
      ?? decodedAspectRatio
      ?? style.placeholderAspectRatio
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

    case .overview:
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
