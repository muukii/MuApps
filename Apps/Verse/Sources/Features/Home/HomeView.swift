//
//  HomeView.swift
//  YouTubeSubtitle
//
//  Created by Hiroshi Kimura on 2025/11/30.
//

import SwiftUI
import SwiftData
import AppIntents
import TypedIdentifier

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

  @State private var selectedVideoItemID: VideoItem.TypedID?
  @State private var showWebView: Bool = false
  @State private var showSettings: Bool = false
  @State private var showURLInput: Bool = false
  @State private var videoToAddToPlaylist: VideoItem?
  private let deepLinkManager = DeepLinkManager.shared
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

  private var selectedVideoItem: VideoItem? {
    guard let selectedVideoItemID else { return nil }
    return history.first { $0.typedID == selectedVideoItemID }
  }

  var body: some View {
    rootLayout
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
                selectedVideoItemID = item.typedID
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
          selectedVideoItemID = item.typedID
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
    .onChange(of: history.map(\.typedID)) { _, ids in
      if let selectedVideoItemID, !ids.contains(selectedVideoItemID) {
        self.selectedVideoItemID = nil
      }
    }
    .task {
      // Initialize sort orders for existing items (migration)
      try? historyService.initializeSortOrders()
    }
  }

  private var rootLayout: some View {
    NavigationSplitView {
      historyContent
        .navigationTitle("Verse")
        .navigationSplitViewColumnWidth(min: 320, ideal: 360, max: 420)
        .toolbar {
          topToolbarContent
        }
        .safeAreaInset(edge: .bottom) {
          historyActionBar
        }
    } detail: {
      detailContent
    }
    .navigationSplitViewStyle(.balanced)
  }

  @ViewBuilder
  private var historyContent: some View {
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
      List(selection: $selectedVideoItemID) {
        ForEach(history) { item in
          historyRow(for: item)
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

  private func historyRow(for item: VideoItem) -> some View {
    let isSelected = selectedVideoItemID == item.typedID

    return NavigationLink(value: item.typedID) {
      VideoItemCell(
        video: item,
        namespace: heroNamespace,
        downloadManager: downloadManager,
        showTimestamp: true
      )
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .background {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
          .overlay {
            if isSelected {
              RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.accentColor.opacity(0.2), lineWidth: 1)
            }
          }
      }
    }
    .buttonStyle(.plain)
    .tag(item.typedID)
    .contextMenu {
      Button {
        videoToAddToPlaylist = item
      } label: {
        Label("Add to Playlist", systemImage: "text.badge.plus")
      }
    }
    .listRowInsets(
      EdgeInsets(
        top: 4,
        leading: 0,
        bottom: 4,
        trailing: 0
      )
    )
    .listRowSeparator(.hidden)
    .listRowBackground(Color.clear)
  }

  @ToolbarContentBuilder
  private var topToolbarContent: some ToolbarContent {
#if os(iOS)
    ToolbarItem(placement: .topBarLeading) {
      settingsToolbarButton
    }

    ToolbarItem(placement: .topBarTrailing) {
      sortToolbarMenu
    }

    ToolbarItem(placement: .primaryAction) {
      if !history.isEmpty && sortOption == .manual {
        EditButton()
      }
    }
#else
    ToolbarItem(placement: .primaryAction) {
      settingsToolbarButton
    }

    ToolbarItem(placement: .secondaryAction) {
      sortToolbarMenu
    }
#endif
  }

  private var settingsToolbarButton: some View {
    Button {
      showSettings = true
    } label: {
      Label("Settings", systemImage: "gear")
    }
  }

  @ViewBuilder
  private var sortToolbarMenu: some View {
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

  private var historyActionBar: some View {
    VStack(spacing: 0) {
      Divider()
      HStack(spacing: 12) {
        Button {
          showURLInput = true
        } label: {
          Label("Paste URL", systemImage: "link")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)

        Button {
          showWebView = true
        } label: {
          Label("Browse YouTube", systemImage: "safari")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
      }
      .padding(.horizontal, 16)
      .padding(.top, 12)
      .padding(.bottom, 16)
      .background(.bar)
    }
  }

  @ViewBuilder
  private var detailContent: some View {
    if let selectedVideoItem {
      playerDestination(for: selectedVideoItem)
    } else {
      ContentUnavailableView {
        Label("Select a Video", systemImage: "play.rectangle")
      } description: {
        Text("Choose a video from your history or add a new one to start watching with synced subtitles.")
      } actions: {
        Button {
          showURLInput = true
        } label: {
          Label("Paste URL", systemImage: "link")
        }
        .buttonStyle(.borderedProminent)

        Button {
          showWebView = true
        } label: {
          Label("Browse YouTube", systemImage: "safari")
        }
        .buttonStyle(.bordered)
      }
    }
  }

  @ViewBuilder
  private func playerDestination(for videoItem: VideoItem) -> some View {
#if os(iOS)
    PlayerView(videoItem: videoItem)
      .id(videoItem.videoID.rawValue)
      .navigationTransition(.zoom(sourceID: videoItem.videoID, in: heroNamespace))
#else
    PlayerView(videoItem: videoItem)
      .id(videoItem.videoID.rawValue)
#endif
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
            selectedVideoItemID = item.typedID
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
          selectedVideoItemID = item.typedID
        }
      }
    }
  }
}

#Preview {
  HomeView()
}
