//
//  SubtitleDisplayView.swift
//  YouTubeSubtitle
//

import SwiftUI

// MARK: - Subtitle Display Type

/// Display type for subtitle rendering
enum SubtitleDisplayType: String, CaseIterable, Identifiable {
  /// Cell-based display using List with SubtitleRowView cells
  case cellBased

  /// Single UITextView using TextKit2 (future implementation)
  case textKit2

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .cellBased:
      return "Cell-based"
    case .textKit2:
      return "TextKit2"
    }
  }
}

// MARK: - Subtitle Display View

/// Umbrella view that switches between different subtitle display implementations
struct SubtitleDisplayView: View {
  let displayType: SubtitleDisplayType
  let model: PlayerModel
  let cues: [Subtitle.Cue]
  let isLoading: Bool
  let error: String?
  let onAction: (SubtitleAction) -> Void

  var body: some View {
    switch displayType {
    case .cellBased:
      SubtitleListViewContainer(
        model: model,
        cues: cues,
        isLoading: isLoading,
        error: error,
        onAction: onAction
      )

    case .textKit2:
      TextKit2SubtitleView(
        model: model,
        cues: cues,
        isLoading: isLoading,
        error: error,
        onAction: onAction
      )
    }
  }
}
