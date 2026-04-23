import AppIntents
import Foundation
import Combine
import SwiftUI

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
@MainActor
final class DeepLinkManager: ObservableObject {
  static let shared = DeepLinkManager()

  @Published var pendingVideoID: YouTubeContentID?

  private init() {}

  func handleURL(_ url: URL) {
    if let videoID = YouTubeURLParser.extractVideoID(from: url) {
      pendingVideoID = videoID
    }
  }
}
