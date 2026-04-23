//
//  OnDeviceTranscribeSheet.swift
//  YouTubeSubtitle
//
//  Created by Claude on 2025/12/09.
//

import SwiftUI

/// Sheet view for on-device transcription workflow.
/// Displays progress through fetching streams, downloading, and transcribing phases.
struct OnDeviceTranscribeSheet: View {
  @Bindable var viewModel: OnDeviceTranscribeViewModel
  let videoID: YouTubeContentID
  let onComplete: (Subtitle) -> Void

  @Environment(DownloadManager.self) private var downloadManager
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(spacing: 24) {
      // Title
      Text("Transcribe Audio")
        .font(.headline)

      // Phase-based content
      phaseContent
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .padding()
    .presentationDetents([.medium])
    .presentationDragIndicator(viewModel.phase.isProcessing ? .hidden : .visible)
    .interactiveDismissDisabled(viewModel.phase.isProcessing)
  }

  @ViewBuilder
  private var phaseContent: some View {
    switch viewModel.phase {
    case .idle:
      idleView

    case .fetchingStreams:
      fetchingStreamsView

    case .downloading(let progress):
      downloadingView(progress: progress)

    case .transcribing(let progress):
      transcribingView(progress: progress)

    case .completed:
      completedView

    case .failed(let message):
      failedView(message: message)
    }
  }

  // MARK: - Phase Views

  private var idleView: some View {
    VStack(spacing: 16) {
      Image(systemName: "waveform.badge.mic")
        .font(.system(size: 48))
        .foregroundStyle(.blue)

      Text("Convert video audio to subtitles using Apple's Speech Recognition.")
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)

      Text("This will temporarily download the video for processing.")
        .font(.caption)
        .foregroundStyle(.tertiary)
        .multilineTextAlignment(.center)

      Button {
        startTranscription()
      } label: {
        Text("Start Transcription")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .padding(.horizontal)
    }
  }

  private var fetchingStreamsView: some View {
    VStack(spacing: 16) {
      ProgressView()
        .scaleEffect(1.5)

      Text("Finding best quality stream...")
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
  }

  private func downloadingView(progress: Double) -> some View {
    VStack(spacing: 16) {
      ProgressView(value: progress) {
        Text("Preparing...")
      } currentValueLabel: {
        Text("\(Int(progress * 100))%")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding(.horizontal)

      Text("Preparing video for transcription")
        .font(.subheadline)
        .foregroundStyle(.secondary)

      Button(role: .destructive) {
        viewModel.cancel()
      } label: {
        Text("Cancel")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.bordered)
      .padding(.horizontal)
    }
  }

  private func transcribingView(progress: Double) -> some View {
    VStack(spacing: 16) {
      ProgressView(value: progress) {
        Text("Transcribing audio...")
      } currentValueLabel: {
        Text("\(Int(progress * 100))%")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding(.horizontal)

      Text("Converting speech to text")
        .font(.subheadline)
        .foregroundStyle(.secondary)

      Button(role: .destructive) {
        viewModel.cancel()
      } label: {
        Text("Cancel")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.bordered)
      .padding(.horizontal)
    }
  }

  private var completedView: some View {
    VStack(spacing: 16) {
      Image(systemName: "checkmark.circle.fill")
        .font(.system(size: 48))
        .foregroundStyle(.green)

      Text("Transcription completed successfully!")
        .font(.subheadline)
        .foregroundStyle(.secondary)

      Button {
        dismiss()
      } label: {
        Text("Done")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .padding(.horizontal)
    }
  }

  private func failedView(message: String) -> some View {
    VStack(spacing: 16) {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.system(size: 48))
        .foregroundStyle(.orange)

      Text("Transcription failed")
        .font(.headline)

      Text(message)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)

      HStack(spacing: 12) {
        Button {
          viewModel.reset()
        } label: {
          Text("Retry")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)

        Button {
          dismiss()
        } label: {
          Text("Close")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
      }
      .padding(.horizontal)
    }
  }

  // MARK: - Actions

  private func startTranscription() {
    Task {
      do {
        let subtitles = try await viewModel.startTranscription(
          videoID: videoID,
          downloadManager: downloadManager
        )
        onComplete(subtitles)
      } catch {
        // Error is already handled by viewModel and displayed in UI
      }
    }
  }
}

#Preview {
  OnDeviceTranscribeSheet(
    viewModel: OnDeviceTranscribeViewModel(),
    videoID: "test123",
    onComplete: { _ in }
  )
}
