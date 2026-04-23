//
//  HomeView.swift
//  YouTubeSubtitle
//
//  Created by Hiroshi Kimura on 2025/11/30.
//

import SwiftUI
import SwiftData
import AppIntents

enum HistorySortOption: String, CaseIterable, Identifiable {
  case manual = "Manual"
  case lastPlayed = "Last Played"
  case dateAdded = "Date Added"

  var id: String { rawValue }

  var systemImage: String {
    switch self {
    case .manual: return "line.3.horizontal"
    case .lastPlayed: return "clock.fill"
    case .dateAdded: return "calendar"
    }
  }
}

struct HomeView: View {
  @Environment(\.modelContext) private var modelContext
  @Environment(VideoItemService.self) private var historyService
  @Environment(VocabularyService.self) private var vocabularyService
  @Environment(DownloadManager.self) private var downloadManager
  @Query(sort: \VideoItem.sortOrder) private var allHistory: [VideoItem]

  @State private var selectedVideoItem: VideoItem?
  @State private var showWebView: Bool = false
  @State private var showSettings: Bool = false
  @State private var showURLInput: Bool = false
  @State private var videoToAddToPlaylist: VideoItem?
  @ObservedObject private var deepLinkManager = DeepLinkManager.shared
  @AppStorage("historySortOption") private var sortOption: HistorySortOption = .manual

  @Namespace private var heroNamespace

  // TODO: Consider moving sorting to SwiftData layer for better performance with large datasets.
  // Current implementation sorts in-memory which may impact performance as history grows.
  // Options: 1) Multiple @Query properties, 2) Manual FetchDescriptor with dynamic sort
  private var history: [VideoItem] {
    switch sortOption {
    case .manual:
      return allHistory
    case .lastPlayed:
      return allHistory.sorted { (item1, item2) in
        // Items with lastPlayedTime come first, sorted by most recent
        switch (item1.lastPlayedTime, item2.lastPlayedTime) {
        case (.some(let date1), .some(let date2)):
          return date1 > date2
        case (.some, .none):
          return true
        case (.none, .some):
          return false
        case (.none, .none):
          // Fall back to timestamp if neither has lastPlayedTime
          return item1.timestamp > item2.timestamp
        }
      }
    case .dateAdded:
      return allHistory.sorted { $0.timestamp > $1.timestamp }
    }
  }

  var body: some View {
    NavigationStack {
      Group {
        // History List
        if history.isEmpty {
          ContentUnavailableView {
            Label("Verse", systemImage: "captions.bubble.fill")
          } description: {
            Text("Watch YouTube videos with synced subtitles.\nPaste a URL or browse YouTube to get started.")
          } actions: {
            Button {
              loadDemoVideo()
            } label: {
              Label("Try Demo Video", systemImage: "play.circle")
            }
            .buttonStyle(.bordered)
          }
        } else {
          List {
            ForEach(history) { item in
              Button {
                selectedVideoItem = item
              } label: {
                VideoItemCell(
                  video: item,
                  namespace: heroNamespace,
                  downloadManager: downloadManager,
                  showTimestamp: true
                )
              }
              .buttonStyle(.plain)
              .contextMenu {
                Button {
                  videoToAddToPlaylist = item
                } label: {
                  Label("Add to Playlist", systemImage: "text.badge.plus")
                }
              }
            }
            .onDelete { indexSet in
              Task {
                for index in indexSet {
                  let item = history[index]
                  try? await historyService.deleteHistoryItem(item)
                }
              }
            }
            .onMove { source, destination in
              // Only allow manual reordering in manual sort mode
              guard sortOption == .manual else { return }
              guard let sourceIndex = source.first else { return }
              try? historyService.moveHistoryItem(from: sourceIndex, to: destination)
            }
          }
          .listStyle(.inset)
        }
      }
      .navigationTitle("")
      .toolbar {
        // Top toolbar - Settings
        ToolbarItem(placement: .topBarLeading) {
          Button {
            showSettings = true
          } label: {
            Label("Settings", systemImage: "gear")
          }
        }

        // Top toolbar - Sort menu
        ToolbarItem(placement: .topBarTrailing) {
          if !history.isEmpty {
            Menu {
              Picker("Sort by", selection: $sortOption) {
                ForEach(HistorySortOption.allCases) { option in
                  Label(option.rawValue, systemImage: option.systemImage)
                    .tag(option)
                }
              }
              .pickerStyle(.inline)
            } label: {
              Label("Sort", systemImage: sortOption.systemImage)
            }
          }
        }

        // Top toolbar - Edit mode for reordering (only in manual mode)
        ToolbarItem(placement: .primaryAction) {
          if !history.isEmpty && sortOption == .manual {
            EditButton()
          }
        }
        // Bottom toolbar - Main actions
        ToolbarItemGroup(placement: .bottomBar) {
          Button {
            showURLInput = true
          } label: {
            Label("Paste URL", systemImage: "link")
          }

          Spacer()

          Button {
            showWebView = true
          } label: {
            Label("Browse YouTube", systemImage: "safari")
          }
        }
      }
      .navigationDestination(item: $selectedVideoItem) { videoItem in
        PlayerView(videoItem: videoItem)
          .navigationTransition(.zoom(sourceID: videoItem.videoID, in: heroNamespace))
      }
      .sheet(isPresented: $showWebView) {
        NavigationStack {
          YouTubeWebView { videoID in
            Task {
              try? await historyService.addToHistory(
                videoID: videoID,
                url: "https://www.youtube.com/watch?v=\(videoID)"
              )
              // Fetch the VideoItem to navigate to PlayerView
              let videoIDRaw = videoID.rawValue
              let descriptor = FetchDescriptor<VideoItem>(
                predicate: #Predicate { $0._videoID == videoIDRaw }
              )
              if let item = try? modelContext.fetch(descriptor).first {
                selectedVideoItem = item
              }
            }
            showWebView = false
          }
          .navigationTitle("YouTube")
          #if os(iOS)
          .navigationBarTitleDisplayMode(.inline)
          #endif
          .toolbar {
            ToolbarItem(placement: .cancellationAction) {
              Button("Close") {
                showWebView = false
              }
            }
          }
        }
      }
      .onChange(of: deepLinkManager.pendingVideoID) { _, newVideoID in
        if let videoID = newVideoID {
          // Fetch the VideoItem for this videoID
          let videoIDRaw = videoID.rawValue
          let descriptor = FetchDescriptor<VideoItem>(
            predicate: #Predicate { $0._videoID == videoIDRaw }
          )
          if let item = try? modelContext.fetch(descriptor).first {
            selectedVideoItem = item
          }
          deepLinkManager.pendingVideoID = nil
        }
      }
      .sheet(isPresented: $showSettings) {
        SettingsView()
          .environment(vocabularyService)
          .environment(historyService)
      }
      .fittingSheet(isPresented: $showURLInput) {
        URLInputSheet { urlText in
          loadURL(urlText)
        }
      }
      .sheet(item: $videoToAddToPlaylist) { video in
        AddToPlaylistSheet(video: video)
      }
      .task {
        // Initialize sort orders for existing items (migration)
        try? historyService.initializeSortOrders()
      }
    }
  }
  
  private func loadURL(_ urlText: String) {
    guard let url = URL(string: urlText), !urlText.isEmpty else {
      return
    }

    // Extract video ID and navigate to player
    if let videoID = YouTubeURLParser.extractVideoID(from: url) {
      Task {
        try? await historyService.addToHistory(videoID: videoID, url: urlText)
        // Fetch the VideoItem to navigate to PlayerView
        let videoIDRaw = videoID.rawValue
        let descriptor = FetchDescriptor<VideoItem>(
          predicate: #Predicate { $0._videoID == videoIDRaw }
        )
        if let item = try? modelContext.fetch(descriptor).first {
          await MainActor.run {
            selectedVideoItem = item
          }
        }
      }
    }
  }

  private func loadDemoVideo() {
    let demoVideoID: YouTubeContentID = "JKpsGXPqMd8"
    let demoURL = "https://www.youtube.com/watch?v=\(demoVideoID)"
    Task {
      try? await historyService.addToHistory(videoID: demoVideoID, url: demoURL)
      // Fetch the VideoItem to navigate to PlayerView
      let videoIDRaw = demoVideoID.rawValue
      let descriptor = FetchDescriptor<VideoItem>(
        predicate: #Predicate { $0._videoID == videoIDRaw }
      )
      if let item = try? modelContext.fetch(descriptor).first {
        await MainActor.run {
          selectedVideoItem = item
        }
      }
    }
  }
}

#Preview {
  HomeView()
}
