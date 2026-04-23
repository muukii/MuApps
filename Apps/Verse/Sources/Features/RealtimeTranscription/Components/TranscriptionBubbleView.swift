//
//  TranscriptionBubbleView.swift
//  YouTubeSubtitle
//
//  Created by Claude on 2025/12/29.
//

import CoreMedia
import SwiftUI

// MARK: - TranscriptionDisplayable Protocol

/// Protocol for types that can be displayed in a transcription bubble
@MainActor
protocol TranscriptionDisplayable: Identifiable {
  var displayText: String { get }
  var displayWordTimings: [Subtitle.WordTiming]? { get }
  var displayFormattedTime: String { get }
}

// MARK: - TranscriptionBubbleView

/// Unified bubble view for displaying transcription entries
/// Used in both live transcription and session history views
struct TranscriptionBubbleView<Item: TranscriptionDisplayable>: View {
  let item: Item
  var highlightTime: CMTime?
  var onExplain: ((String) -> Void)?
  var onSelectionChanged: ((String?) -> Void)?
  var onShowActions: ((String) -> Void)?

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      SelectableSubtitleTextView(
        content: .init(text: item.displayText, wordTimings: item.displayWordTimings),
        highlightTime: highlightTime,
        onExplain: onExplain,
        onSelectionChanged: onSelectionChanged,
        onShowActions: onShowActions
      )
      .fixedSize(horizontal: false, vertical: true)

      Text(item.displayFormattedTime)
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
    .padding(12)
    .background(Color(.secondarySystemBackground))
    .clipShape(RoundedRectangle(cornerRadius: 12))
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
