//
//  YouTubePlayerWrapper.swift
//  YouTubeSubtitle
//
//  1st Party YouTube Player Implementation
//
//  This is a custom implementation using YouTube iFrame Player API directly,
//  replacing the dependency on YouTubePlayerKit.
//
//  Architecture:
//  - YouTubeVideoPlayer: SwiftUI View (UIViewRepresentable)
//  - YouTubeVideoPlayerController: Manages playback state and API calls
//  - YouTubePlayerWebView: WKWebView hosting iFrame API
//
//  Why 1st Party?
//  YouTubePlayerKit 2.x had an issue where playbackState was not correctly
//  synchronized due to `.receive(on: DispatchQueue.main)` combined with @MainActor,
//  causing timing issues where isPlaying would not reflect the actual state.
//

import Combine
import Foundation
import SwiftUI

// MARK: - YouTubeVideoPlayer

/// SwiftUI View for YouTube video playback.
/// Usage: YouTubeVideoPlayer(controller: controller)
struct YouTubeVideoPlayer: View {
  let controller: YouTubeVideoPlayerController

  var body: some View {
    ZStack {
      if !controller.isReady {
        ProgressView()
      }
      YouTubeVideoPlayerRepresentable(controller: controller)
        .opacity(controller.isReady ? 1 : 0)
    }
  }
}

// MARK: - YouTubeVideoPlayerRepresentable

/// UIViewRepresentable wrapper for YouTubePlayerWebView
private struct YouTubeVideoPlayerRepresentable: UIViewRepresentable {
  let controller: YouTubeVideoPlayerController

  func makeUIView(context: Context) -> YouTubePlayerWebView {
    controller.webView
  }

  func updateUIView(_ uiView: YouTubePlayerWebView, context: Context) {
    // No updates needed - controller manages the webView
  }
}

// MARK: - YouTubeVideoPlayerController

/// Controller for YouTube video playback.
/// Conforms to VideoPlayerController protocol for unified playback control.
///
/// ## YouTube iFrame API State Reference
/// - `-1`: unstarted - Player has not started
/// - `0`: ended - Video has finished playing
/// - `1`: playing - Video is currently playing
/// - `2`: paused - Video is paused
/// - `3`: buffering - Video is buffering
/// - `5`: cued - Video is cued and ready to play
///
@Observable
@MainActor
final class YouTubeVideoPlayerController: VideoPlayerController {

  // MARK: - Properties

  /// The web view hosting the YouTube player
  let webView: YouTubePlayerWebView

  /// Current playback state (updated synchronously from JS events)
  /// This avoids the timing issues from YouTubePlayerKit 2.x's
  /// `.receive(on: DispatchQueue.main)` in playbackStatePublisher
  private(set) var playbackState: YouTubePlayerWebView.PlaybackState = .unstarted

  private var _playbackRate: Double = 1.0

  /// Tracks if user explicitly initiated playback (to block auto-play on first seek)
  private var userInitiatedPlay: Bool = false

  /// Whether the player is ready to receive API calls (set after priming completes)
  private(set) var isReady: Bool = false

  private var eventCancellable: AnyCancellable?

  // MARK: - Initialization

  init(videoID: String) {
    self.webView = YouTubePlayerWebView()

    setupEventHandling()

    // Load the video
    webView.loadVideo(videoID: videoID, autoplay: false, controls: true)
  }

  private func setupEventHandling() {
    eventCancellable = webView.eventPublisher
      .sink { [weak self] event in
        guard let self else { return }

        switch event {
        case .ready:
          // Prime the player: mute → play → pause → seek(0) → unmute
          // This prevents auto-play on subsequent seeks
          // isReady is set to true AFTER priming completes
          Task { @MainActor in
            await self.webView.mute()
            await self.webView.play()
            // Wait for player to actually start playing
            try? await Task.sleep(for: .milliseconds(300))
            await self.webView.pause()
            await self.webView.seek(to: 0)
            await self.webView.unmute()
            self.isReady = true
          }

        case .stateChange(let state):
          // Update state synchronously (no dispatch delay)
          self.playbackState = state

          // TODO: Block auto-play triggered by first seek (YouTube API quirk)
          // Temporarily disabled for testing
          // if state == .playing && !self.userInitiatedPlay {
          //   Task { @MainActor in
          //     await self.webView.pause()
          //   }
          // }

        case .error(let code):
          // Log error for debugging
          // Error codes: 2=invalid param, 5=HTML5 error, 100=not found, 101/150=embed blocked
          #if DEBUG
          print("[YouTubeVideoPlayerController] Error: \(code)")
          #endif
        }
      }
  }

  // MARK: - VideoPlayerController

  var isPlaying: Bool {
    playbackState.isPlaying
  }

  var currentTime: Double {
    get async {
      guard isReady else { return 0 }
      return await webView.getCurrentTime()
    }
  }

  var duration: Double {
    get async {
      guard isReady else { return 0 }
      return await webView.getDuration()
    }
  }

  var playbackRate: Double {
    _playbackRate
  }

  func play() async {
    guard isReady else { return }
    userInitiatedPlay = true
    await webView.play()
  }

  func pause() async {
    guard isReady else { return }
    await webView.pause()
  }

  func seek(to time: Double) async {
    guard isReady else { return }
    await webView.seek(to: time)
  }

  func setPlaybackRate(_ rate: Double) async {
    guard isReady else { return }
    _playbackRate = rate
    await webView.setPlaybackRate(rate)
  }
}

// MARK: - Preview

#Preview {
  YouTubePlayerPreview()
}

private struct YouTubePlayerPreview: View {
  @State private var controller = YouTubeVideoPlayerController(videoID: "oBEytIA9mF0")
  @State private var currentTime: Double = 0
  @State private var duration: Double = 0

  var body: some View {
    VStack(spacing: 16) {
      YouTubeVideoPlayer(controller: controller)
        .aspectRatio(16/9, contentMode: .fit)

      // Status display
      VStack(spacing: 8) {
        Text("Ready: \(controller.isReady ? "✓" : "...")")
        Text("State: \(controller.playbackState.description)")
        Text("Time: \(String(format: "%.1f", currentTime)) / \(String(format: "%.1f", duration))")
        Text("Rate: \(String(format: "%.2fx", controller.playbackRate))")
      }
      .font(.caption.monospaced())

      // Controls
      HStack(spacing: 20) {
        Button("Play") {
          Task { await controller.play() }
        }
        Button("Pause") {
          Task { await controller.pause() }
        }
        Button("Seek +10s") {
          Task {
            let time = await controller.currentTime
            await controller.seek(to: time + 10)
          }
        }
      }
    }
    .padding()
    .task {
      // Poll current time every 0.5 seconds
      while !Task.isCancelled {
        currentTime = await controller.currentTime
        duration = await controller.duration
        try? await Task.sleep(for: .milliseconds(500))
      }
    }
  }
}

extension YouTubePlayerWebView.PlaybackState: CustomStringConvertible {
  var description: String {
    switch self {
    case .unstarted: return "unstarted"
    case .ended: return "ended"
    case .playing: return "playing"
    case .paused: return "paused"
    case .buffering: return "buffering"
    case .cued: return "cued"
    }
  }
}
