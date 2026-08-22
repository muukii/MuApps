import AVFoundation
import SwiftUI

/// Video preview source for either an unsaved draft or a saved card.
public struct VideoContentSource: Equatable, Sendable {
  public let fileURL: URL?
  public let fileRevision: Int
  public let displayAspectRatio: CGFloat?

  public init(
    fileURL: URL? = nil,
    fileRevision: Int = 0,
    pixelSize: CGSize? = nil
  ) {
    self.fileURL = fileURL
    self.fileRevision = fileRevision
    self.displayAspectRatio = pixelSize?.contentAspectRatio
  }
}

/// Renders looping video content with stable placeholder geometry.
struct VideoContentView: View {

  /// Visual and playback treatment owned by video content.
  struct Style {
    let preset: EntryContentStyle

    init(_ preset: EntryContentStyle) {
      self.preset = preset
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
  }

  let video: VideoContentSource
  let style: Style
  @State private var playableFileURL: URL?
  @State private var readyFileURL: URL?

  var body: some View {
    ContentMediaFrame(aspectRatio: displayAspectRatio) {
      content
    }
    .task(
      id: ContentFileLoadID(
        fileURL: video.fileURL,
        fileRevision: video.fileRevision
      )
    ) {
      await refreshMedia()
    }
  }

  @ViewBuilder
  private var content: some View {
    if let fileURL = playableFileURL {
      playableVideo(fileURL)
    } else {
      ContentMediaPlaceholder(
        systemImage: "video",
        aspectRatio: displayAspectRatio
      )
    }
  }

  /// Keeps the placeholder and player states on one placement geometry.
  ///
  /// Persisted pixel dimensions describe the video before `AVPlayerLayer`
  /// reports a presentation size, so the Cell can reserve its final box on the
  /// first layout pass.
  private var displayAspectRatio: CGFloat {
    switch style.preset {
    case .composer:
      return style.placeholderAspectRatio
    case .cell:
      return video.displayAspectRatio ?? style.placeholderAspectRatio
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
      .opacity(readyFileURL == fileURL ? 1 : 0)

      if readyFileURL != fileURL {
        ContentMediaPlaceholder(
          systemImage: "video",
          aspectRatio: displayAspectRatio
        )
      }
    }
    .clipped()
    .overlay(alignment: .bottomTrailing) {
      ContentMediaBadge(systemImage: "speaker.slash.fill")
    }
  }

  @MainActor
  private func refreshMedia() async {
    playableFileURL = nil
    readyFileURL = nil

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
