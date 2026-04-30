import AppIntents
import Foundation
import Observation

struct OpenYouTubeVideoIntent: AppIntent {
  static let title: LocalizedStringResource = "Open YouTube Video"
  static let description: IntentDescription = "Open a YouTube video in YouTubeSubtitle app"
  static let openAppWhenRun: Bool = true
  
  @Parameter(title: "YouTube URL")
  var url: URL
  
  func perform() async throws -> some IntentResult {
    // アプリを起動してURLを開く
    // DeepLinkManagerを使ってURLを処理
    await MainActor.run {
      DeepLinkManager.shared.handleURL(url)
    }
    
    return .result()
  }
}

// DeepLinkを管理するシングルトン
@Observable
@MainActor
final class DeepLinkManager {
  static let shared = DeepLinkManager()

  var pendingVideoID: YouTubeContentID?

  private init() {}

  func handleURL(_ url: URL) {
    if let videoID = YouTubeURLParser.extractVideoID(from: url) {
      pendingVideoID = videoID
    }
  }
}
