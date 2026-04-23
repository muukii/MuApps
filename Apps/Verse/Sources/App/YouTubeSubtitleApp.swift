//
//  YouTubeSubtitleApp.swift
//  YouTubeSubtitle
//
//  Created by Hiroshi Kimura on 2025/11/30.
//

import SwiftData
import SwiftUI
import TipKit

@main
struct YouTubeSubtitleApp: App {

  let modelContainer: ModelContainer
  let downloadManager: DownloadManager

  init() {
    // Configure audio session for video playback (allows audio in silent mode)
    _ = AudioSessionManager.shared

    // Configure ModelContainer with all schemas
    let schema = Schema([
      VideoItem.self,
      DownloadStateEntity.self,
      VocabularyItem.self,
      VocabularyExample.self,
      TranscriptionSession.self,
      TranscriptionEntry.self,
      Playlist.self,
      PlaylistEntry.self,
    ])

    do {
      modelContainer = try ModelContainer(for: schema)
      self.downloadManager = DownloadManager(modelContainer: modelContainer)
    } catch {
      // Migration failed - delete existing database and retry
      print("ModelContainer creation failed: \(error). Deleting database and retrying...")
      Self.deleteSwiftDataStore()
      
      do {
        modelContainer = try ModelContainer(for: schema)
        self.downloadManager = DownloadManager(modelContainer: modelContainer)
      } catch {
        fatalError("Failed to create ModelContainer after database reset: \(error)")
      }
    }
  }

  /// Delete SwiftData SQLite files to reset the database
  private static func deleteSwiftDataStore() {
    let fileManager = FileManager.default
    guard let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
      return
    }

    // SwiftData stores files with "default.store" prefix
    let storeFiles = ["default.store", "default.store-shm", "default.store-wal"]

    for fileName in storeFiles {
      let fileURL = appSupportURL.appendingPathComponent(fileName)
      try? fileManager.removeItem(at: fileURL)
    }
  }

  var body: some Scene {
    WindowGroup {
      ContentView()
        .task {
          // Configure TipKit
          try? Tips.configure([
            .displayFrequency(.immediate)
          ])
          await downloadManager.restorePendingDownloads()
        }
    }
    .defaultSize(width: 800, height: 600)
    .modelContainer(modelContainer)
    .environment(downloadManager)
  }
}
