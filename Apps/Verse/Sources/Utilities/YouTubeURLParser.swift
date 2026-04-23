//
//  YouTubeURLParser.swift
//  YouTubeSubtitle
//
//  Created by Claude Code
//

import Foundation
import YouTubeKit

struct YouTubeURLParser {
  /// Extracts the video ID from a YouTube URL using YouTubeKit
  static func extractVideoID(from url: URL) -> YouTubeContentID? {
    let youtube = YouTube(url: url)
    return YouTubeContentID(rawValue: youtube.videoID)
  }
  
  /// Converts a YouTube URL to an embedded player URL
  static func makeEmbedURL(from url: URL) -> URL? {
    guard let videoID = extractVideoID(from: url) else {
      return nil
    }
    
    return URL(string: "https://www.youtube.com/embed/\(videoID)")
  }
  
  /// Creates a YouTube object from URL for metadata and streams access
  static func makeYouTube(from url: URL) -> YouTube {
    return YouTube(url: url)
  }
}
