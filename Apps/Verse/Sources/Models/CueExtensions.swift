//
//  CueExtensions.swift
//  YouTubeSubtitle
//
//  Created by Claude on 2025/12/01.
//

import Foundation
import YoutubeTranscript

// MARK: - TranscriptResponse Extensions

extension Array where Element == TranscriptResponse {
  /// Convert TranscriptResponse array to Subtitle format
  func toSubtitle() -> Subtitle {
    SubtitleAdapter.toSubtitle(self)
  }
}
