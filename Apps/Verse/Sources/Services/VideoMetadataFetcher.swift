import Foundation
@preconcurrency import YouTubeKit

struct VideoMetadata {
  let title: String?
  let author: String?
  let thumbnailURL: String?
}

@MainActor
final class VideoMetadataFetcher {
  
  static func fetch(videoID: YouTubeContentID) async -> VideoMetadata {
    do {
      let youtube = YouTube(videoID: videoID.rawValue)
      let metadata = try await youtube.metadata
      
      return VideoMetadata(
        title: metadata?.title,
        author: nil, // YouTubeKitでは作者名が直接取得できない
        thumbnailURL: metadata?.thumbnail?.url.absoluteString
      )
    } catch {
      print("Failed to fetch metadata: \(error)")
      return VideoMetadata(
        title: nil,
        author: nil,
        thumbnailURL: nil
      )
    }
  }
}
