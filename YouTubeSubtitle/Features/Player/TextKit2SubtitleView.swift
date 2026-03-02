//
//  TextKit2SubtitleView.swift
//  YouTubeSubtitle
//

import SwiftUI

// MARK: - TextKit2 Subtitle View

/// SwiftUI wrapper for TextKit2-based subtitle display.
/// Displays all subtitles in a single scrollable UITextView using TextKit2.
struct TextKit2SubtitleView: View {
  let model: PlayerModel
  let cues: [Subtitle.Cue]
  let isLoading: Bool
  let error: String?
  let onAction: (SubtitleAction) -> Void

  @State private var isTrackingEnabled: Bool = true

  var body: some View {
    Group {
      if isLoading {
        ProgressView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if let error {
        errorView(error: error)
      } else if cues.isEmpty {
        emptyView
      } else {
        subtitleTextView
          .overlay(alignment: .bottomTrailing) {
            trackingButton
          }
      }
    }
  }

  // MARK: - Subtitle Text View

  private var subtitleTextView: some View {
    // Read currentTime.value here to trigger SwiftUI observation
    let currentTimeValue = model.currentTime.value

    return TextKit2SubtitleTextView(
      cues: cues,
      currentTimeValue: currentTimeValue,
      currentCueID: model.currentCueID,
      isTrackingEnabled: $isTrackingEnabled,
      onAction: onAction
    )
  }

  // MARK: - Tracking Button

  private var trackingButton: some View {
    Button {
      isTrackingEnabled.toggle()
    } label: {
      Image(systemName: "arrow.up.left.circle")
        .font(.system(size: 28))
        .foregroundStyle(isTrackingEnabled ? .primary : .secondary)
    }
    .buttonStyle(.glassProminent)
    .frame(width: 48, height: 48)
    .padding(12)
  }

  // MARK: - Error View

  private func errorView(error: String) -> some View {
    VStack(spacing: 12) {
      Image(systemName: "exclamationmark.triangle")
        .font(.system(size: 40))
        .foregroundStyle(.orange)
      Text("Failed to load subtitles")
        .font(.headline)
      Text(error)
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  // MARK: - Empty View

  private var emptyView: some View {
    ContentUnavailableView(
      "No Subtitles",
      systemImage: "text.bubble",
      description: Text("No subtitles available for this video")
    )
  }
}
