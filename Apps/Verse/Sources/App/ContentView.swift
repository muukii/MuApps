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

  var body: some View {
    Group {
      if let historyService {
        HomeView()
          .environment(historyService)
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
    }
  }
}

#Preview {
  ContentView()
}
