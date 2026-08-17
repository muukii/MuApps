import AVFoundation
import SwiftUI

#if canImport(UIKit)
  import UIKit
#endif

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
    // Poster frames are generated with the track's preferred transform applied,
    // so their header dimensions describe the displayed video for older
    // resources that were persisted without explicit pixel dimensions.
    self.displayAspectRatio =
      pixelSize?.contentAspectRatio
      ?? EncodedImageDimensions.displayAspectRatio(from: thumbnailData)
  }
}

/// Renders looping video content with a stable poster-frame boundary.
struct VideoContentView: View {

  /// Visual and playback treatment owned by video content.
  struct Style {
    let preset: EntryContentStyle

    init(_ preset: EntryContentStyle) {
      self.preset = preset
    }

    var contentMode: ContentMode {
      .fill
    }

    /// Geometry used until any dimensions are known for this video.
    var placeholderAspectRatio: CGFloat {
      switch preset {
      case .composer:
        return 1
      case .cell:
        return 16 / 9
      }
    }

    var minimumHeight: CGFloat? {
      switch preset {
      case .composer:
        return nil
      case .cell:
        return 180
      }
    }
  }

  let video: VideoContentSource
  let style: Style
  @State private var thumbnailImage: UIImage?
  @State private var playableFileURL: URL?
  @State private var readyFileURL: URL?

  var body: some View {
    ContentMediaFrame(aspectRatio: displayAspectRatio) {
      content
    }
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
        aspectRatio: displayAspectRatio
      )
    }
  }

  /// Keeps the placeholder, poster, and player states on one placement geometry.
  ///
  /// Persisted pixel dimensions describe the video before its poster decodes and
  /// long before `AVPlayerLayer` reports a presentation size, so the Cell can
  /// reserve its final box on the first layout pass.
  private var displayAspectRatio: CGFloat {
    switch style.preset {
    case .composer:
      return thumbnailImage?.contentAspectRatio ?? style.placeholderAspectRatio
    case .cell:
      return
        video.displayAspectRatio
        ?? thumbnailImage?.contentAspectRatio
        ?? style.placeholderAspectRatio
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
    // The poster cross-fade must crop exactly like the layer's
    // `resizeAspectFill` so it cannot spill outside the reserved box when the
    // persisted dimensions and the decoded poster disagree.
    .clipped()
    .overlay(alignment: .bottomTrailing) {
      ContentMediaBadge(systemImage: "speaker.slash.fill")
    }
  }

  private func posterOnly(_ image: UIImage) -> some View {

    Image(uiImage: image)
      .resizable()
      .aspectRatio(displayAspectRatio, contentMode: style.contentMode)
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

#Preview("Video Content — 9:16") {
  EntryContentPreviewCanvas {
    VideoContentView(
      video: VideoContentSource(
        pixelSize: CGSize(width: 1_080, height: 1_920)
      ),
      style: .init(.cell)
    )
  }
}
