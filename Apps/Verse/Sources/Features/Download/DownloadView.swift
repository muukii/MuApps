//
//  DownloadView.swift
//  YouTubeSubtitle
//
//  Created by Hiroshi Kimura on 2025/12/04.
//

import SwiftData
import SwiftUI
import YouTubeKit

struct DownloadView: View {
  let videoID: YouTubeContentID

  @Environment(\.dismiss) private var dismiss
  @Environment(\.modelContext) private var modelContext
  @Environment(DownloadManager.self) private var downloadManager

  @State private var streams: [YouTubeKit.Stream] = []
  @State private var isLoadingStreams: Bool = false
  @State private var streamError: (any Error)?

  @State private var selectedStream: YouTubeKit.Stream?

  @State private var transcriptionState: TranscriptionService.TranscriptionState = .idle

  /// Check if file is already downloaded (persisted in SwiftData)
  private var isAlreadyDownloaded: Bool {
    let videoIDRaw = videoID.rawValue
    let descriptor = FetchDescriptor<VideoItem>(
      predicate: #Predicate { $0._videoID == videoIDRaw }
    )
    guard let item = try? modelContext.fetch(descriptor).first else {
      return false
    }
    return item.isDownloaded
  }

  /// Current download progress from DownloadManager
  private var currentProgress: DownloadProgress? {
    downloadManager.downloadProgress(for: videoID)
  }

  /// Map DownloadManager state to view state
  private var downloadState: ViewDownloadState {
    // First check if already downloaded (persisted)
    if isAlreadyDownloaded {
      return .alreadyDownloaded
    }

    // Then check active download progress
    guard let progress = currentProgress else { return .idle }
    switch progress.state {
    case .pending, .downloading:
      return .downloading(progress.fractionCompleted)
    case .completed:
      return .completed
    case .failed:
      return .failed("Download failed")
    case .cancelled:
      return .failed("Download cancelled")
    }
  }

  enum ViewDownloadState: Equatable {
    case idle
    case downloading(Double)
    case completed
    case alreadyDownloaded
    case failed(String)
  }

  /// Only show progressive MP4 streams (AVPlayer compatible)
  private var availableStreams: [YouTubeKit.Stream] {
    YouTubeStreamService.filterProgressiveMP4(streams)
  }

  var body: some View {
    VStack(spacing: 0) {
      // Content
      ScrollView {
        VStack(spacing: 24) {
          // Quality Selection
          qualitySelectionSection

          // Download Progress (when downloading or completed)
          if case .idle = downloadState {
            // No download status to show
          } else {
            downloadStatusSection
          }

          // Transcription Progress (when transcribing or completed)
          if transcriptionState != .idle {
            transcriptionStatusSection
          }
        }
        .padding(20)
      }

      // Bottom Button
      downloadButton
    }
    .background(Color(.systemGroupedBackground))
    .navigationTitle("Download")
    #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
    #endif
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button("Close") {
          dismiss()
        }
      }
    }
    .task {
      await loadStreams()
    }
  }

  // MARK: - Quality Selection Section

  private var qualitySelectionSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Select Quality")
        .font(.headline)
        .foregroundStyle(.primary)

      if isLoadingStreams {
        loadingView
      } else if let error = streamError {
        errorView(error: error)
      } else if availableStreams.isEmpty {
        emptyView
      } else {
        VStack(spacing: 8) {
          ForEach(availableStreams, id: \.url) { stream in
            QualityOptionRow(
              stream: stream,
              isSelected: selectedStream?.url == stream.url,
              onSelect: { selectedStream = stream }
            )
          }
        }
      }
    }
  }

  private var loadingView: some View {
    HStack(spacing: 12) {
      ProgressView()
      Text("Loading available qualities...")
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 40)
  }

  private func errorView(error: any Error) -> some View {
    VStack(spacing: 12) {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.system(size: 40))
        .foregroundStyle(.orange)
      Text("Failed to load")
        .font(.headline)
      Text(error.localizedDescription)
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
      Button("Retry") {
        Task { await loadStreams() }
      }
      .buttonStyle(.bordered)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 20)
  }

  private var emptyView: some View {
    VStack(spacing: 12) {
      Image(systemName: "arrow.down.circle.dotted")
        .font(.system(size: 40))
        .foregroundStyle(.secondary)
      Text("No downloadable formats")
        .font(.headline)
      Text("This video doesn't have compatible formats for download.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 20)
  }

  // MARK: - Download Status Section

  private var downloadStatusSection: some View {
    VStack(spacing: 12) {
      switch downloadState {
      case .idle:
        EmptyView()

      case .downloading(let progress):
        VStack(spacing: 8) {
          ProgressView(value: progress)
            .tint(.blue)
          HStack {
            Text("Downloading...")
              .font(.subheadline)
              .foregroundStyle(.secondary)
            Spacer()
            Text("\(Int(progress * 100))%")
              .font(.subheadline.monospacedDigit())
              .foregroundStyle(.secondary)
          }

          // Cancel button
          Button {
            cancelDownload()
          } label: {
            Text("Cancel")
              .font(.subheadline)
              .foregroundStyle(.red)
          }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))

      case .completed, .alreadyDownloaded:
        HStack(spacing: 12) {
          Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 24))
            .foregroundStyle(.green)
          VStack(alignment: .leading, spacing: 2) {
            Text(downloadState == .alreadyDownloaded ? "Already Downloaded" : "Download Complete")
              .font(.subheadline.weight(.medium))
            Text("Video saved to local storage")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer()
        }
        .padding(16)
        .background(Color.green.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))

      case .failed(let message):
        HStack(spacing: 12) {
          Image(systemName: "xmark.circle.fill")
            .font(.system(size: 24))
            .foregroundStyle(.red)
          VStack(alignment: .leading, spacing: 2) {
            Text("Download Failed")
              .font(.subheadline.weight(.medium))
            Text(message)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer()
        }
        .padding(16)
        .background(Color.red.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
      }
    }
  }

  // MARK: - Transcription Status Section

  private var transcriptionStatusSection: some View {
    VStack(spacing: 12) {
      switch transcriptionState {
      case .idle:
        EmptyView()

      case .preparingAssets:
        HStack(spacing: 12) {
          ProgressView()
          VStack(alignment: .leading, spacing: 2) {
            Text("Preparing Speech Model")
              .font(.subheadline.weight(.medium))
            Text("Downloading language assets...")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer()
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))

      case .transcribing(let progress):
        VStack(spacing: 8) {
          HStack(spacing: 12) {
            Image(systemName: "waveform")
              .font(.system(size: 20))
              .foregroundStyle(.purple)
            Text("Transcribing Audio")
              .font(.subheadline.weight(.medium))
            Spacer()
          }
          ProgressView(value: progress)
            .tint(.purple)
          HStack {
            Text("Converting speech to text...")
              .font(.caption)
              .foregroundStyle(.secondary)
            Spacer()
            Text("\(Int(progress * 100))%")
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
          }
        }
        .padding(16)
        .background(Color.purple.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))

      case .completed:
        HStack(spacing: 12) {
          Image(systemName: "text.bubble.fill")
            .font(.system(size: 24))
            .foregroundStyle(.purple)
          VStack(alignment: .leading, spacing: 2) {
            Text("Transcription Complete")
              .font(.subheadline.weight(.medium))
            Text("Subtitles generated from audio")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer()
        }
        .padding(16)
        .background(Color.purple.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))

      case .failed(let message):
        HStack(spacing: 12) {
          Image(systemName: "waveform.slash")
            .font(.system(size: 24))
            .foregroundStyle(.orange)
          VStack(alignment: .leading, spacing: 2) {
            Text("Transcription Failed")
              .font(.subheadline.weight(.medium))
            Text(message)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(2)
          }
          Spacer()
        }
        .padding(16)
        .background(Color.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
      }
    }
  }

  // MARK: - Download Button

  private var downloadButton: some View {
    VStack(spacing: 0) {
      Divider()
      Button {
        Task { await startDownload() }
      } label: {
        HStack(spacing: 8) {
          if case .downloading = downloadState {
            ProgressView()
              .tint(.white)
          } else {
            Image(systemName: "arrow.down.circle.fill")
          }
          Text(downloadButtonTitle)
        }
        .font(.headline)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
      }
      .buttonStyle(.borderedProminent)
      .disabled(!canDownload)
      .padding(20)
    }
    .background(Color(.systemGroupedBackground))
  }

  private var downloadButtonTitle: String {
    switch downloadState {
    case .idle:
      return "Download"
    case .downloading:
      return "Downloading..."
    case .completed, .alreadyDownloaded:
      return "Downloaded"
    case .failed:
      return "Retry Download"
    }
  }

  private var canDownload: Bool {
    guard selectedStream != nil else { return false }
    switch downloadState {
    case .idle, .failed:
      return true
    case .downloading, .completed, .alreadyDownloaded:
      return false
    }
  }

  // MARK: - Methods

  private func loadStreams() async {
    isLoadingStreams = true
    streamError = nil
    streams = []

    do {
      // Use shared YouTubeStreamService for fetching
      let fetchedStreams = try await YouTubeStreamService.fetchStreams(videoID: videoID)

      await MainActor.run {
        // Streams already sorted by resolution (highest first) from service
        streams = fetchedStreams
        isLoadingStreams = false

        // Auto-select highest quality progressive mp4
        if let best = YouTubeStreamService.selectStream(
          from: streams,
          strategy: .highest
        ) {
          selectedStream = best
        }
      }
    } catch {
      await MainActor.run {
        streamError = error
        isLoadingStreams = false
      }
    }
  }

  private func startDownload() async {
    guard let stream = selectedStream else { return }

    do {
      // Queue download with DownloadManager
      try await downloadManager.queueDownload(
        videoID: videoID,
        stream: stream
      )

      // Note: Progress is automatically shown in Live Activity by BGContinuedProcessingTask
      // The UI will update reactively from downloadManager.activeDownloads
    } catch {
      // Show error (DownloadManager handles state internally)
      print("Failed to queue download: \(error)")
    }
  }

  private func cancelDownload() {
    downloadManager.cancelDownloads(for: videoID)
  }

  private func startTranscription(fileURL: URL) async {
    do {
      let subtitles = try await TranscriptionService.shared.transcribe(
        fileURL: fileURL
      ) { state in
        Task { @MainActor in
          transcriptionState = state
        }
      }

      // Save transcription result to VideoItem
      let videoIDRaw = videoID.rawValue
      let descriptor = FetchDescriptor<VideoItem>(
        predicate: #Predicate { $0._videoID == videoIDRaw }
      )
      if let item = try? modelContext.fetch(descriptor).first {
        item.cachedSubtitles = subtitles
      }
    } catch {
      await MainActor.run {
        transcriptionState = .failed(error.localizedDescription)
      }
    }
  }
}

// MARK: - Quality Option Row

private struct QualityOptionRow: View {
  let stream: YouTubeKit.Stream
  let isSelected: Bool
  let onSelect: () -> Void

  var body: some View {
    Button(action: onSelect) {
      HStack(spacing: 12) {
        // Selection indicator
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
          .font(.system(size: 22))
          .foregroundStyle(isSelected ? .blue : .secondary)

        // Quality info
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 6) {
            if let resolution = stream.videoResolution {
              Text("\(resolution)p")
                .font(.body.weight(.medium))

              if resolution >= 720 {
                Text("HD")
                  .font(.caption.weight(.semibold))
                  .foregroundStyle(.white)
                  .padding(.horizontal, 6)
                  .padding(.vertical, 2)
                  .background(Color.blue)
                  .clipShape(RoundedRectangle(cornerRadius: 4))
              }
            }
          }

          HStack(spacing: 8) {
            Text(stream.fileExtension.rawValue.uppercased())
              .font(.caption)
              .foregroundStyle(.secondary)

            if let bitrate = stream.bitrate {
              Text("•")
                .foregroundStyle(.secondary)
              Text(formatBitrate(bitrate))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        }

        Spacer()
      }
      .padding(16)
      .background(
        RoundedRectangle(cornerRadius: 12)
          .fill(Color(.secondarySystemGroupedBackground))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 12)
          .strokeBorder(isSelected ? Color.blue : Color.clear, lineWidth: 2)
      )
    }
    .buttonStyle(.plain)
  }

  private func formatBitrate(_ bitrate: Int) -> String {
    if bitrate >= 1_000_000 {
      return String(format: "%.1f Mbps", Double(bitrate) / 1_000_000)
    } else {
      return String(format: "%.0f kbps", Double(bitrate) / 1_000)
    }
  }
}

#Preview {
  NavigationStack {
    DownloadView(videoID: "JKpsGXPqMd8")
  }
}
