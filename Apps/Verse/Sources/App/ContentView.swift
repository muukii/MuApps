//
//  ContentView.swift
//  YouTubeSubtitle
//
//  Created by Hiroshi Kimura on 2025/11/30.
//

import SwiftData
import SwiftUI

struct ContentView: View {
  @Environment(\.modelContext) private var modelContext
  @Environment(DownloadManager.self) private var downloadManager
  @State private var historyService: VideoItemService?
  @State private var vocabularyService: VocabularyService?

  var body: some View {
    Group {
      if let historyService, let vocabularyService {
        HomeView()
          .environment(historyService)
          .environment(vocabularyService)
      } else {
        ProgressView()
      }
    }
    .onAppear {
      if historyService == nil {
        historyService = VideoItemService(
          modelContext: modelContext,
          downloadManager: downloadManager
        )
      }
      if vocabularyService == nil {
        vocabularyService = VocabularyService(modelContext: modelContext)
      }
    }
  }
}

#Preview {
  ContentView()
}
