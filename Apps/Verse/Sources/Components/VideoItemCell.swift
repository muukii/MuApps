import SwiftUI
import AsyncMultiplexImage
import AsyncMultiplexImage_Nuke

// MARK: - VideoItemCell

/// A unified video item cell component used across the app.
struct VideoItemCell: View {
  let video: VideoItem
  var namespace: Namespace.ID?
  var downloadManager: DownloadManager?
  var showTimestamp: Bool = false

  private let thumbnailSize = CGSize(width: 120, height: 68)
  private let cornerRadius: CGFloat = 8

  /// Download progress from DownloadManager
  private var downloadProgress: DownloadProgress? {
    downloadManager?.downloadProgress(for: video.videoID)
  }

  /// Playback progress (0.0 to 1.0) for progress bar display
  private var playbackProgress: Double? {
    guard let position = video.lastPlaybackPosition,
          let duration = video.duration,
          duration > 0 else { return nil }
    return min(max(position / duration, 0), 1)
  }

  var body: some View {
    HStack(spacing: 12) {
      thumbnailView
        .overlay(alignment: .bottomTrailing) {
          if FeatureFlags.shared.isDownloadFeatureEnabled, downloadManager != nil {
            downloadStatusBadge
          }
        }

      VStack(alignment: .leading, spacing: 4) {
        Text(video.title ?? video.videoID.rawValue)
          .font(.headline)
          .lineLimit(2)

        if let author = video.author {
          Text(author)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }

        if showTimestamp || (FeatureFlags.shared.isDownloadFeatureEnabled && downloadProgress != nil) {
          HStack(spacing: 6) {
            if showTimestamp {
              Text(formatDate(video.timestamp))
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }

            if FeatureFlags.shared.isDownloadFeatureEnabled, let progress = downloadProgress {
              downloadStatusText(for: progress)
            }
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .contentShape(Rectangle())
    .modifier(MatchedTransitionModifier(id: video.videoID, namespace: namespace))
  }

  // MARK: - Thumbnail View

  @ViewBuilder
  private var thumbnailView: some View {
    if let thumbnailURLString = video.thumbnailURL,
       let thumbnailURL = URL(string: thumbnailURLString) {
      AsyncMultiplexImageNuke(
        imageRepresentation: .remote(.init(constant: thumbnailURL))
      )
      .aspectRatio(contentMode: .fill)
      .frame(width: thumbnailSize.width, height: thumbnailSize.height)
      .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
      .overlay(alignment: .bottom) {
        playbackProgressBar
      }
    } else {
      Rectangle()
        .fill(Color.gray.opacity(0.3))
        .frame(width: thumbnailSize.width, height: thumbnailSize.height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .overlay {
          Image(systemName: "play.rectangle")
            .foregroundStyle(.white)
            .font(.title)
        }
        .overlay(alignment: .bottom) {
          playbackProgressBar
        }
    }
  }

  // MARK: - Playback Progress Bar

  @ViewBuilder
  private var playbackProgressBar: some View {
    if let progress = playbackProgress {
      GeometryReader { geometry in
        Rectangle()
          .fill(Color.red)
          .frame(width: geometry.size.width * progress, height: 3)
      }
      .frame(height: 3)
      .clipShape(
        UnevenRoundedRectangle(
          bottomLeadingRadius: cornerRadius,
          bottomTrailingRadius: progress >= 0.99 ? cornerRadius : 0
        )
      )
    }
  }

  // MARK: - Download Status Badge

  @ViewBuilder
  private var downloadStatusBadge: some View {
    if let progress = downloadProgress {
      switch progress.state {
      case .pending, .downloading:
        ZStack {
          Circle()
            .fill(.ultraThinMaterial)
            .frame(width: 28, height: 28)
          CircularProgressView(progress: progress.fractionCompleted)
            .frame(width: 20, height: 20)
        }
        .padding(4)

      case .completed:
        Image(systemName: "checkmark.circle.fill")
          .font(.system(size: 20))
          .foregroundStyle(.white)
          .background(Circle().fill(.white).padding(2))
          .padding(4)

      case .failed, .cancelled:
        Image(systemName: "exclamationmark.circle.fill")
          .font(.system(size: 20))
          .foregroundStyle(.orange)
          .background(Circle().fill(.white).padding(2))
          .padding(4)
      }
    } else if video.isDownloaded {
      Image(systemName: "checkmark.circle.fill")
        .font(.system(size: 20))
        .foregroundStyle(.white)
        .background(Circle().fill(.white).padding(2))
        .padding(4)
    }
  }

  // MARK: - Download Status Text

  @ViewBuilder
  private func downloadStatusText(for progress: DownloadProgress) -> some View {
    switch progress.state {
    case .pending:
      Text("Pending...")
        .font(.caption2)
        .foregroundStyle(.secondary)
    case .downloading:
      Text("Downloading \(Int(progress.fractionCompleted * 100))%")
        .font(.caption2)
        .foregroundStyle(.blue)
    case .completed:
      Text("Downloaded")
        .font(.caption2)
        .foregroundStyle(.green)
    case .failed:
      Text("Failed")
        .font(.caption2)
        .foregroundStyle(.red)
    case .cancelled:
      Text("Cancelled")
        .font(.caption2)
        .foregroundStyle(.orange)
    }
  }

  // MARK: - Helpers

  private func formatDate(_ date: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: date, relativeTo: Date())
  }
}

// MARK: - Matched Transition Modifier

private struct MatchedTransitionModifier: ViewModifier {
  let id: YouTubeContentID
  let namespace: Namespace.ID?

  func body(content: Content) -> some View {
    if let namespace = namespace {
      content.matchedTransitionSource(id: id, in: namespace)
    } else {
      content
    }
  }
}

// MARK: - Circular Progress View

private struct CircularProgressView: View {
  let progress: Double

  var body: some View {
    ZStack {
      Circle()
        .stroke(Color.gray.opacity(0.3), lineWidth: 3)

      Circle()
        .trim(from: 0, to: progress)
        .stroke(Color.blue, style: StrokeStyle(lineWidth: 3, lineCap: .round))
        .rotationEffect(.degrees(-90))
        .animation(.linear(duration: 0.3), value: progress)
    }
  }
}
