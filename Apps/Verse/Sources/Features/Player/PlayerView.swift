//
//  PlayerView.swift
//  YouTubeSubtitle
//
//  Created by Hiroshi Kimura on 2025/11/30.
//

import AVKit
import ObjectEdge
import SwiftData
import SwiftUI
import TipKit
import YouTubeKit
import YoutubeTranscript
import Translation

struct PlayerView: View {
  let videoItem: VideoItem

  @Environment(\.modelContext) private var modelContext
  @Environment(\.scenePhase) private var scenePhase
  @Environment(DownloadManager.self) private var downloadManager
  @Environment(VideoItemService.self) private var historyService
  @ObjectEdge private var model = PlayerModel()

  // Subtitle state
  @State private var currentSubtitles: Subtitle?
  @State private var isLoadingTranscripts: Bool = false
  @State private var transcriptError: String?

  // Sheet state
  @State private var showDownloadView: Bool = false

  // UI state
  @State private var height: CGFloat = 0
  @State private var isPlayerCollapsed: Bool = false

  // Transcription state
  @State private var isTranscribing: Bool = false
  @State private var transcriptionState: TranscriptionService.TranscriptionState = .idle
  @State private var showTranscriptionSheet: Bool = false

  // Subtitle interaction state
  @State private var selectedCueForTranslation: Subtitle.Cue?
  @State private var selectionForActionSheet: TextSelection?

  // On-device transcribe state
  @State private var onDeviceTranscribeViewModel = OnDeviceTranscribeViewModel()

  // Settings
  @AppStorage("autoTranscribeEnabled") private var autoTranscribeEnabled: Bool = true
  @AppStorage("subtitleDisplayType") private var subtitleDisplayType: SubtitleDisplayType = .cellBased

  // Playback position state
  @State private var savePositionTask: Task<Void, Never>?
  @State private var hasRestoredPosition: Bool = false

  // Computed property to access videoID from the entity
  private var videoID: YouTubeContentID { videoItem.videoID }

  /// Returns true when transcription is actively in progress (preparing or transcribing)
  /// Used to prevent interactive dismissal of the sheet during processing
  private var isTranscriptionInProgress: Bool {
    switch transcriptionState {
    case .preparingAssets, .transcribing:
      return true
    case .idle, .completed, .failed:
      return false
    }
  }

  /// Determines the phase to display for the OnDeviceTranscribeButton.
  /// Prioritizes ViewModel's processing state over subtitle existence check.
  private var transcriptionButtonPhase: OnDeviceTranscribeViewModel.Phase {
    let vmPhase = onDeviceTranscribeViewModel.phase
    switch vmPhase {
    case .fetchingStreams, .downloading, .transcribing, .failed:
      return vmPhase
    case .idle, .completed:
      // Only show completed if subtitles have word timing (from on-device transcription)
      if let subtitles = currentSubtitles, !needsOnDeviceTranscription(subtitles) {
        return .completed
      }
      return .idle
    }
  }

  var body: some View {
    if let controller = model.controller {

      ZStack {

        VStack {
          VideoPlayerSection(controller: controller)
            .compositingGroup()
            .animation(.smooth) {              
              $0.opacity(isPlayerCollapsed ? 0 : 1)
                .scaleEffect(isPlayerCollapsed ? 0.95 : 1, anchor: .center)              
            }
            .onGeometryChange(for: CGFloat.self, of: \.size.height) { newValue in
              self.height = newValue
            }                  
        }
        .frame(maxHeight: .infinity, alignment: .top)

        VStack {
          
          Color.clear
            .animation(.smooth) {              
              $0
                .frame(height: isPlayerCollapsed ? 0 : height)
            }
          
          VStack {
            // Player collapse toggle button
            Button {
              withAnimation(.smooth) {
                isPlayerCollapsed.toggle()
              }
            } label: {
              HStack(spacing: 6) {
                Image(systemName: isPlayerCollapsed ? "chevron.down" : "chevron.up")
                  .font(.system(size: 12, weight: .semibold))
                Text(isPlayerCollapsed ? "Show Player" : "Hide Player")
                  .font(.caption)
              }
              .foregroundStyle(.secondary)
              .padding(.vertical, 8)
              .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            
            subtitleSection
            
            PlayerControls(model: model)
          }
          .background(
            UnevenRoundedRectangle(
              topLeadingRadius: 24,
              bottomLeadingRadius: 0,
              bottomTrailingRadius: 0,
              topTrailingRadius: 24,
              style: .continuous
            )
            .foregroundStyle(.appPlayerBackground)
          )
        }

      }
      .onChange(of: model.isControllerReady) { _, isReady in
        // Restore playback position when player is ready (after priming for YouTube)
        if isReady && !hasRestoredPosition {
          hasRestoredPosition = true
          restorePlaybackPosition()
          startPeriodicPositionSaving()
        }
      }

      .background(.appPlayerBackground)
      .toolbar {
       toolbarContent
      }
      .sheet(isPresented: $showDownloadView) {
        NavigationStack {
          DownloadView(videoID: videoID)
        }
      }
      .sheet(isPresented: $showTranscriptionSheet) {
        TranscriptionProgressSheet(
          transcriptionState: transcriptionState,
          onStart: {
            transcribeVideo()
          },
          onDismiss: {
            showTranscriptionSheet = false
          }
        )
        .presentationDetents([.medium])
        .presentationDragIndicator(isTranscriptionInProgress ? .hidden : .visible)
        .interactiveDismissDisabled(isTranscriptionInProgress)
      }
      .translationPresentation(
        isPresented: Binding(
          get: { selectedCueForTranslation != nil },
          set: { if !$0 { selectedCueForTranslation = nil } }
        ),
        text: selectedCueForTranslation?.decodedText ?? ""
      )
      .sheet(item: $selectionForActionSheet) { selection in
        SelectionActionSheet(
          selection: selection,
          onCopy: { selectionForActionSheet = nil },
          onDismiss: { selectionForActionSheet = nil }
        )
      }
      .onDisappear {
        // Save playback position before leaving
        savePlaybackPosition()
        // Cancel periodic save task
        savePositionTask?.cancel()
        savePositionTask = nil
        model.cleanup()
      }
      .onChange(of: scenePhase) { _, newPhase in
        model.handleScenePhaseChange(to: newPhase)
        // Save playback position when app goes to background
        if newPhase == .background {
          savePlaybackPosition()
        }
      }
      .onChange(of: videoItem.isDownloaded) { _, isDownloaded in
        // When download completes, automatically switch to local playback
        if isDownloaded, model.playbackSource == .youtube, let fileURL = videoItem.downloadedFileURL {
          model.localFileURL = fileURL
          model.switchToLocal()
        }
      }
      .onChange(of: currentSubtitles?.cues) { _, newCues in
        // Update model's cues when subtitles change
        model.cues = newCues ?? []
      }
    } else {
      ProgressView()
        .onAppear {
          model.loadVideo(videoItem: videoItem)
          fetchTranscripts(videoID: videoID)
        }
    }
  }
  
  @ToolbarContentBuilder
  var toolbarContent: some ToolbarContent {
    ToolbarItem(placement: .primaryAction) {
      HStack(spacing: 16) {
        // On-device transcribe button (only when no local file exists)
        if model.localFileURL == nil {
          OnDeviceTranscribeButton(
            phase: transcriptionButtonPhase,
            action: { startBackgroundTranscription() }
          )
          .popoverTip(TranscribeTip())
        }

        SubtitleManagementView(
          videoID: videoID,
          subtitles: currentSubtitles,
          localFileURL: model.localFileURL,
          playbackSource: model.playbackSource,
          onSubtitlesImported: { subtitles in
            currentSubtitles = subtitles
          },
          onPlaybackSourceChange: { source in
            if source == .youtube {
              model.switchToYouTube(videoID: videoID.rawValue)
            } else {
              model.switchToLocal()
            }
          },
          onLocalVideoDeleted: {
            model.localFileURL = nil
          },
          onTranscribe: {
            showTranscriptionSheet = true
          },
          isTranscribing: isTranscribing
        )

        if FeatureFlags.shared.isDownloadFeatureEnabled {
          DownloadButton(
            state: downloadButtonState,
            onTap: { showDownloadView = true }
          )
        }
      }
    }
  }

  // MARK: - Subtitle Section

  private var subtitleSection: some View {
    VStack(alignment: .leading, spacing: 0) {
      SubtitleDisplayView(
        displayType: subtitleDisplayType,
        model: model,
        cues: currentSubtitles?.cues ?? [],
        isLoading: isLoadingTranscripts,
        error: transcriptError,
        onAction: { action in
          switch action {
          case .tap(let time):
            model.seek(to: time)
          case .setRepeatA(let time):
            model.repeatStartTime = time
          case .setRepeatB(let time):
            model.repeatEndTime = time
          case .setRepeatRange(let startTime, let endTime):
            model.repeatStartTime = startTime
            model.repeatEndTime = endTime
          case .explain(let cue):
            // Redirect to SelectionActionSheet
            selectionForActionSheet = TextSelection(text: cue.decodedText, context: buildContextForCue(cue))
          case .translate(let cue):
            selectedCueForTranslation = cue
          case .explainSelection(let text, let context):
            // Redirect to SelectionActionSheet
            selectionForActionSheet = TextSelection(text: text, context: context)
          case .showSelectionActions(let text, let context):
            selectionForActionSheet = TextSelection(text: text, context: context)
          }
        }
      )
    }
  }

  // MARK: - Download Button State

  private var downloadButtonState: DownloadButton.State {
    // Check active download progress first
    if let progress = downloadManager.downloadProgress(for: videoID) {
      switch progress.state {
      case .pending:
        return .pending
      case .downloading:
        return .downloading(progress.fractionCompleted)
      case .completed:
        return .completed
      case .failed, .cancelled:
        return .failed
      }
    }
    // Check persisted download status from VideoItem
    if videoItem.isDownloaded {
      return .completed
    }
    return .idle
  }

  // MARK: - Private Methods

  private func fetchTranscripts(videoID: YouTubeContentID) {
    isLoadingTranscripts = true
    transcriptError = nil
    currentSubtitles = nil

    Task {
      // Check cache first
      let videoIDRaw = videoID.rawValue
      let descriptor = FetchDescriptor<VideoItem>(
        predicate: #Predicate { $0._videoID == videoIDRaw }
      )

      if let historyItem = try? modelContext.fetch(descriptor).first,
         let cached = historyItem.cachedSubtitles,
         !cached.cues.isEmpty {
        await MainActor.run {
          currentSubtitles = cached
          isLoadingTranscripts = false

          // Auto-start on-device transcription if needed (no word timings yet)
          if autoTranscribeEnabled && needsOnDeviceTranscription(cached) && model.localFileURL == nil {
            startBackgroundTranscription()
          }
        }
        return
      }

      // Fetch from network
      do {
        let config = TranscriptConfig(lang: nil)
        let fetchedTranscripts = try await YoutubeTranscript.fetchTranscript(
          for: videoID.rawValue,
          config: config
        )

        let subtitles = fetchedTranscripts.toSubtitle()

        // Save to cache
        try? historyService.updateCachedSubtitles(videoID: videoID, subtitles: subtitles)

        await MainActor.run {
          currentSubtitles = subtitles
          isLoadingTranscripts = false

          // Auto-start on-device transcription after YouTube subtitles are loaded
          if autoTranscribeEnabled && needsOnDeviceTranscription(subtitles) && model.localFileURL == nil {
            startBackgroundTranscription()
          }
        }
      } catch {
        await MainActor.run {
          transcriptError = error.localizedDescription
          isLoadingTranscripts = false

          // Auto-start on-device transcription when YouTube captions are not available
          // Only if no local file exists (on-device transcription downloads the video)
          if autoTranscribeEnabled && model.localFileURL == nil {
            startBackgroundTranscription()
          }
        }
      }
    }
  }

  private func transcribeVideo() {
    guard let fileURL = model.localFileURL else { return }

    isTranscribing = true
    transcriptionState = .idle

    Task {
      do {
        let subtitles = try await TranscriptionService.shared.transcribe(
          fileURL: fileURL,
          locale: Locale(identifier: "en_US")
        ) { state in
          transcriptionState = state
        }

        // Update UI with transcribed subtitles and persist to SwiftData
        await MainActor.run {
          currentSubtitles = subtitles
          isTranscribing = false
          transcriptionState = .completed

          // Save to SwiftData for persistence across app launches
          try? historyService.updateCachedSubtitles(videoID: videoID, subtitles: subtitles)
        }

      } catch {
        await MainActor.run {
          transcriptionState = .failed(error.localizedDescription)
          isTranscribing = false
        }
      }
    }
  }

  /// Starts on-device transcription in the background (download + transcribe)
  private func startBackgroundTranscription() {
    Task {
      do {
        let subtitles = try await onDeviceTranscribeViewModel.startTranscription(
          videoID: videoID,
          downloadManager: downloadManager
        )
        currentSubtitles = subtitles
        transcriptError = nil
        try? historyService.updateCachedSubtitles(videoID: videoID, subtitles: subtitles)
      } catch {
        // Error is already captured in viewModel.phase
      }
    }
  }

  /// Determines if on-device transcription is needed for the given subtitles.
  /// Returns true if subtitles are empty or don't have word-level timing (from on-device transcription).
  private func needsOnDeviceTranscription(_ subtitles: Subtitle?) -> Bool {
    guard let subtitles, !subtitles.cues.isEmpty else { return true }
    // If any cue has wordTimings, it's from on-device transcription
    return !subtitles.cues.contains { $0.hasWordTimings }
  }

  // MARK: - Playback Position

  /// Save current playback position to SwiftData for resume functionality
  private func savePlaybackPosition() {
    let position = model.currentTime.value
    let duration = model.duration
    // Only save if position is meaningful (more than 5 seconds)
    guard position > 5 else { return }
    try? historyService.updatePlaybackPosition(
      videoID: videoID,
      position: position,
      duration: duration > 0 ? duration : nil
    )
  }

  /// Restore saved playback position when video loads (without auto-playing)
  private func restorePlaybackPosition() {
    guard let savedPosition = videoItem.lastPlaybackPosition, savedPosition > 0 else { return }
    model.seek(to: savedPosition)
  }

  /// Start periodic playback position saving (every 30 seconds)
  private func startPeriodicPositionSaving() {
    // Cancel any existing task
    savePositionTask?.cancel()

    savePositionTask = Task { @MainActor in
      while !Task.isCancelled {
        // Wait 30 seconds
        try? await Task.sleep(for: .seconds(30))

        guard !Task.isCancelled else { break }

        // Save position if video is playing or paused (but loaded)
        if model.isControllerReady {
          savePlaybackPosition()
        }
      }
    }
  }

  // MARK: - Context Building

  /// Build context string from surrounding subtitle cues for LLM explanation.
  /// Includes 2 cues before and 2 cues after the selected cue for better context.
  private func buildContextForCue(_ cue: Subtitle.Cue) -> String {
    guard let cues = currentSubtitles?.cues,
          let currentIndex = cues.firstIndex(where: { $0.id == cue.id }) else {
      return cue.decodedText
    }

    // Get 2 cues before and 2 cues after
    let contextRange = 2
    let startIndex = max(0, currentIndex - contextRange)
    let endIndex = min(cues.count - 1, currentIndex + contextRange)

    // Build context with the selected cue marked
    var contextLines: [String] = []
    for i in startIndex...endIndex {
      let contextCue = cues[i]
      if i == currentIndex {
        // Mark the selected cue clearly
        contextLines.append(">>> \(contextCue.decodedText) <<<")
      } else {
        contextLines.append(contextCue.decodedText)
      }
    }

    return contextLines.joined(separator: "\n")
  }
}

// MARK: - Nested Components

extension PlayerView {

  // MARK: - VideoPlayerSection

  struct VideoPlayerSection: View {
    let controller: PlayerController

    var body: some View {
      Group {
        switch controller {
        case .youtube(let controller):
          YouTubeVideoPlayer(controller: controller)
        case .local(let controller):
          LocalVideoPlayer(controller: controller)
        }
      }
      .aspectRatio(16 / 9, contentMode: .fit)
      .clipShape(RoundedRectangle(cornerRadius: 12))
      .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
      .padding(.horizontal, 16)
      .padding(.top, 16)
    }
  }

  // MARK: - TranscriptionProgressSheet

  struct TranscriptionProgressSheet: View {
    let transcriptionState: TranscriptionService.TranscriptionState
    let onStart: () -> Void
    let onDismiss: () -> Void

    var body: some View {
      VStack(spacing: 24) {
        // Title
        Text("Transcribe Audio")
          .font(.headline)

        // State-based content
        Group {
          switch transcriptionState {
          case .idle:
            VStack(spacing: 16) {
              Image(systemName: "waveform.badge.mic")
                .font(.system(size: 48))
                .foregroundStyle(.blue)

              Text("Convert video audio to subtitles using Apple's Speech Recognition.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

              Button {
                onStart()
              } label: {
                Text("Start Transcription")
                  .frame(maxWidth: .infinity)
              }
              .buttonStyle(.borderedProminent)
              .padding(.horizontal)
            }

          case .preparingAssets:
            VStack(spacing: 16) {
              ProgressView()
                .scaleEffect(1.5)

              Text("Preparing speech recognition model...")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }

          case .transcribing(let progress):
            VStack(spacing: 16) {
              ProgressView(value: progress) {
                Text("Transcribing...")
              } currentValueLabel: {
                Text("\(Int(progress * 100))%")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }

              Text("Processing audio...")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }

          case .completed:
            VStack(spacing: 16) {
              Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)

              Text("Transcription completed successfully!")
                .font(.subheadline)
                .foregroundStyle(.secondary)

              Button {
                onDismiss()
              } label: {
                Text("Done")
                  .frame(maxWidth: .infinity)
              }
              .buttonStyle(.borderedProminent)
              .padding(.horizontal)
            }

          case .failed(let message):
            VStack(spacing: 16) {
              Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.orange)

              Text("Transcription failed")
                .font(.headline)

              Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

              Button {
                onDismiss()
              } label: {
                Text("Close")
                  .frame(maxWidth: .infinity)
              }
              .buttonStyle(.bordered)
              .padding(.horizontal)
            }
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      .padding()
    }
  }

  // MARK: - DownloadButton

  struct DownloadButton: View {
    enum State: Equatable {
      case idle
      case pending
      case downloading(Double)
      case completed
      case failed
    }

    let state: State
    let onTap: () -> Void

    var body: some View {
      Button(action: onTap) {
        buttonContent
      }
    }

    @ViewBuilder
    private var buttonContent: some View {
      switch state {
      case .idle:
        Label("Download", systemImage: "arrow.down.circle")

      case .pending:
        Label {
          Text("Pending")
        } icon: {
          ProgressView()
            .scaleEffect(0.8)
        }

      case .downloading(let progress):
        Label {
          Text("\(Int(progress * 100))%")
        } icon: {
          ZStack {
            Circle()
              .stroke(Color.gray.opacity(0.3), lineWidth: 2)
            Circle()
              .trim(from: 0, to: progress)
              .stroke(Color.blue, style: StrokeStyle(lineWidth: 2, lineCap: .round))
              .rotationEffect(.degrees(-90))
          }
          .frame(width: 18, height: 18)
        }

      case .completed:
        Label("Downloaded", systemImage: "checkmark.circle.fill")

      case .failed:
        Label("Retry", systemImage: "exclamationmark.circle")
      }
    }
  }
}

// MARK: - On-Device Transcribe Button

/// Toolbar button that shows on-device transcription state
private struct OnDeviceTranscribeButton: View {
  let phase: OnDeviceTranscribeViewModel.Phase
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Group {
        switch phase {
        case .idle:
          Image(systemName: "waveform.badge.mic")
            .font(.system(size: 16))
        case .completed:
          Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 18))
            .foregroundStyle(.green)
        case .fetchingStreams:
          ProgressView()
            .controlSize(.small)
        case .downloading(let progress):
          CircularProgressView(progress: progress, systemImage: "arrow.down")
        case .transcribing(let progress):
          CircularProgressView(progress: progress, systemImage: "waveform")
        case .failed:
          Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 18))
            .foregroundStyle(.orange)
        }
      }
      .frame(width: 32, height: 32)
    }
    .disabled(phase.isProcessing)
  }
}

/// Circular progress indicator with icon
private struct CircularProgressView: View {
  let progress: Double
  let systemImage: String

  var body: some View {
    ZStack {
      Circle()
        .stroke(Color.secondary.opacity(0.3), lineWidth: 2)
      Circle()
        .trim(from: 0, to: progress)
        .stroke(Color.blue, style: StrokeStyle(lineWidth: 2, lineCap: .round))
        .rotationEffect(.degrees(-90))
        .animation(.linear(duration: 0.1), value: progress)
      Image(systemName: systemImage)
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.blue)
    }
    .frame(width: 22, height: 22)
  }
}

// MARK: - Playback Source

enum PlaybackSource {
  case youtube
  case local

  var displayName: String {
    switch self {
    case .youtube: return "YouTube"
    case .local: return "Local"
    }
  }
}

#Preview {
  let container = try! ModelContainer(
    for: VideoItem.self,
    configurations: ModelConfiguration(isStoredInMemoryOnly: true)
  )
  let downloadManager = DownloadManager(modelContainer: container)
  let historyService = VideoItemService(
    modelContext: container.mainContext,
    downloadManager: downloadManager
  )

  let item = VideoItem(
    videoID: "oRc4sndVaWo",
    url: "https://www.youtube.com/watch?v=oRc4sndVaWo",
    title: "Preview Video"
  )

  return NavigationStack {
    PlayerView(videoItem: item)
  }
  .modelContainer(container)
  .environment(downloadManager)
  .environment(historyService)
}

