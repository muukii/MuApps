//
//  TextKit2SubtitleTextView.swift
//  YouTubeSubtitle
//
//  Thin UIViewRepresentable wrapper for TextKit2SubtitlePlayerTextView.
//

import ScrollEdgeEffect
import SwiftUI

// MARK: - TextKit2SubtitleTextView

/// UIViewRepresentable that wraps the production TextKit 2 subtitle reader.
/// Provides a thin interface between SwiftUI playback state and the UIKit text view.
struct TextKit2SubtitleTextView: UIViewRepresentable {

  // MARK: - Properties

  let cues: [Subtitle.Cue]
  let currentTimeValue: Double
  let currentCueID: Subtitle.Cue.ID?
  @Binding var isTrackingEnabled: Bool
  @Binding var scrollEdgeVisibility: ScrollEdgeEffect.Visibility
  let onAction: (SubtitleAction) -> Void

  // MARK: - UIViewRepresentable

  func makeUIView(context: Context) -> TextKit2SubtitlePlayerTextView {
    let textView = TextKit2SubtitlePlayerTextView()

    textView.onTapAtTime = { time in
      onAction(.tap(time: time))
    }

    textView.onActionButton = { _, cueText in
      onAction(.showSelectionActions(text: cueText, context: cueText))
    }

    textView.onSelectText = { text, context in
      onAction(.showSelectionActions(text: text, context: context))
    }

    textView.onTrackingShouldPause = { [binding = $isTrackingEnabled] in
      binding.wrappedValue = false
    }

    textView.onScrollEdgeVisibilityChange = { [binding = $scrollEdgeVisibility] visibility in
      binding.wrappedValue = visibility
    }

    context.coordinator.textView = textView

    return textView
  }

  func updateUIView(_ textView: TextKit2SubtitlePlayerTextView, context: Context) {
    let coordinator = context.coordinator

    let cuesChanged = coordinator.lastCues != cues
    if cuesChanged {
      coordinator.lastCues = cues
      textView.setCues(cues)
    }

    let forcesScroll = isTrackingEnabled && !coordinator.wasTrackingEnabled
    coordinator.wasTrackingEnabled = isTrackingEnabled

    textView.setPlaybackState(
      currentTime: currentTimeValue,
      currentCueID: currentCueID,
      tracksCurrentCue: isTrackingEnabled,
      forcesScroll: forcesScroll
    )
  }

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  // MARK: - Coordinator

  class Coordinator {
    weak var textView: TextKit2SubtitlePlayerTextView?
    var lastCues: [Subtitle.Cue] = []
    var wasTrackingEnabled: Bool = true
  }
}

// MARK: - Preview

private struct TextKit2SubtitleTextViewPreview: View {
  @State private var currentTime: Double = 3.2
  @State private var isTrackingEnabled = true
  @State private var scrollEdgeVisibility = ScrollEdgeEffect.Visibility.hidden
  @State private var lastActionDescription = "No action yet"

  var body: some View {
    VStack(spacing: 0) {
      TextKit2SubtitleTextView(
        cues: Self.previewCues,
        currentTimeValue: currentTime,
        currentCueID: currentCueID,
        isTrackingEnabled: $isTrackingEnabled,
        scrollEdgeVisibility: $scrollEdgeVisibility,
        onAction: handleAction(_:)
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)

      Divider()

      VStack(alignment: .leading, spacing: 12) {
        HStack {
          Text(timeLabel(currentTime))
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)

          Spacer()

          Toggle("Track", isOn: $isTrackingEnabled)
            .font(.caption)
        }

        Slider(
          value: $currentTime,
          in: 0...Self.previewDuration,
          step: 0.05
        )

        Text(lastActionDescription)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
      .padding(16)
      .background(.thinMaterial)
    }
    .background(Color(uiColor: .systemBackground))
  }

  private var currentCueID: Subtitle.Cue.ID? {
    Self.previewCues.last { cue in
      currentTime >= cue.startTime
    }?.id
  }

  private func handleAction(_ action: SubtitleAction) {
    switch action {
    case .tap(let time):
      currentTime = time
      lastActionDescription = "Seek: \(timeLabel(time))"
    case .setRepeatA(let time):
      lastActionDescription = "Set A: \(timeLabel(time))"
    case .setRepeatB(let time):
      lastActionDescription = "Set B: \(timeLabel(time))"
    case .setRepeatRange(let startTime, let endTime):
      lastActionDescription = "Repeat: \(timeLabel(startTime)) - \(timeLabel(endTime))"
    case .explain(let cue):
      lastActionDescription = "Explain cue \(cue.id)"
    case .translate(let cue):
      lastActionDescription = "Translate cue \(cue.id)"
    case .explainSelection(let text, _):
      lastActionDescription = "Explain selection: \(text)"
    case .showSelectionActions(let text, _):
      lastActionDescription = "Actions: \(text)"
    }
  }

  private func timeLabel(_ time: Double) -> String {
    String(format: "%.2fs", time)
  }

  private static var previewDuration: Double {
    previewCues.last?.endTime ?? 1
  }

  private static let previewCues: [Subtitle.Cue] = [
    Subtitle.Cue(
      id: 1,
      startTime: 0.0,
      endTime: 2.4,
      text: "TextKit 2 keeps every subtitle in one continuous layout surface."
    ),
    Subtitle.Cue(
      id: 2,
      startTime: 2.4,
      endTime: 5.2,
      text: "Word timing can color text without forcing SwiftUI to rebuild every row.",
      wordTimings: [
        Subtitle.WordTiming(text: "Word", startTime: 2.4, endTime: 2.7),
        Subtitle.WordTiming(text: "timing", startTime: 2.7, endTime: 3.1),
        Subtitle.WordTiming(text: "can", startTime: 3.1, endTime: 3.3),
        Subtitle.WordTiming(text: "color", startTime: 3.3, endTime: 3.6),
        Subtitle.WordTiming(text: "text", startTime: 3.6, endTime: 3.9),
      ]
    ),
    Subtitle.Cue(
      id: 3,
      startTime: 5.2,
      endTime: 8.1,
      text: "A longer cue wraps across multiple lines so the action attachment below it can be measured against the proposed line fragment width."
    ),
    Subtitle.Cue(
      id: 4,
      startTime: 8.1,
      endTime: 10.6,
      text: "字幕、日本語、emoji 🙂, and composed characters cafe\u{301} should keep the ranges honest."
    ),
    Subtitle.Cue(
      id: 5,
      startTime: 10.6,
      endTime: 13.4,
      text: "Use the slider to force cue changes and check tracking re-enable behavior."
    ),
  ]
}

#Preview("TextKit2 Subtitle Text View") {
  TextKit2SubtitleTextViewPreview()
}
