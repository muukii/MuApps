//
//  TextKit2SubtitleTextView.swift
//  YouTubeSubtitle
//
//  Thin UIViewRepresentable wrapper for KaraokeTextView.
//

import SwiftUI

// MARK: - TextKit2SubtitleTextView

/// UIViewRepresentable that wraps KaraokeTextView for SwiftUI usage.
/// Provides a thin interface between SwiftUI and the pure UIKit karaoke text view.
struct TextKit2SubtitleTextView: UIViewRepresentable {

  // MARK: - Properties

  let cues: [Subtitle.Cue]
  let currentTimeValue: Double
  let currentCueID: Subtitle.Cue.ID?
  @Binding var isTrackingEnabled: Bool
  let onAction: (SubtitleAction) -> Void

  // MARK: - UIViewRepresentable

  func makeUIView(context: Context) -> KaraokeTextView {
    let textView = KaraokeTextView()

    // Set up callbacks
    textView.onTapAtTime = { time in
      onAction(.tap(time: time))
    }

    textView.onActionButton = { _, cueText in
      onAction(.showSelectionActions(text: cueText, context: cueText))
    }

    textView.onSelectText = { text, context in
      onAction(.showSelectionActions(text: text, context: context))
    }

    textView.onScroll = { [binding = $isTrackingEnabled] in
      binding.wrappedValue = false
    }

    context.coordinator.textView = textView

    return textView
  }

  func updateUIView(_ textView: KaraokeTextView, context: Context) {
    let coordinator = context.coordinator

    // Check if cues changed
    let cuesChanged = coordinator.lastCues != cues
    if cuesChanged {
      coordinator.lastCues = cues
      textView.setCues(cues)
    }

    // Update highlighting
    textView.updateCurrentTime(currentTimeValue)

    // Auto-scroll if tracking enabled and cue changed
    if isTrackingEnabled, let currentCueID {
      textView.scrollToCue(id: currentCueID, animated: true)
    }
  }

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  // MARK: - Coordinator

  class Coordinator {
    weak var textView: KaraokeTextView?
    var lastCues: [Subtitle.Cue] = []
  }
}
