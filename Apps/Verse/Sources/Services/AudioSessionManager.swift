//
//  AudioSessionManager.swift
//  YouTubeSubtitle
//
//  Created by Claude on 2025/12/05.
//

import AVFoundation

/// Manages AVAudioSession configuration for the app.
/// Configures audio session to allow video playback even when device is in silent mode,
/// and enables mixing with other audio (background music).
@Observable
final class AudioSessionManager: Sendable {
  static let shared = AudioSessionManager()

  /// Whether the audio session has been configured at least once.
  private(set) var isConfigured: Bool = false
  private(set) var configurationError: (any Error)?

  /// Current active state of the audio session.
  private(set) var isActive: Bool = false

  private init() {
    configureAudioSession()
  }

  // MARK: - Configuration

  /// Configures the audio session with settings suitable for video playback.
  ///
  /// - Category: `.playback` — prioritizes this app's audio output (works in silent mode).
  /// - Mode: `.moviePlayback` — enables bass boost and surround sound for video content.
  /// - Option: `.mixWithOthers` — allows mixing with other audio sources (e.g., background music).
  private func configureAudioSession() {
    let audioSession = AVAudioSession.sharedInstance()

    do {
      try audioSession.setCategory(
        .playback,
        mode: .moviePlayback,
        options: [.mixWithOthers]
      )
      isConfigured = true
    } catch {
      configurationError = error
      print("[AudioSessionManager] Failed to configure audio session category: \(error.localizedDescription)")
    }
  }

  // MARK: - Activation

  /// Activates the audio session with video playback settings.
  ///
  /// Call this before starting video playback (YouTube or local). It reconfigures the
  /// category and activates the session, ensuring that background music continues playing
  /// alongside the video audio.
  func activate() {
    let audioSession = AVAudioSession.sharedInstance()

    do {
      // Reconfigure category first (may change if settings were modified externally)
      try audioSession.setCategory(
        .playback,
        mode: .moviePlayback,
        options: [.mixWithOthers]
      )
      // Activate with notifyOthersOnDeactivation so other audio apps can resume when this ends
      try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
      isActive = true
      print("[AudioSessionManager] Audio session activated for video playback")
    } catch {
      print("[AudioSessionManager] Failed to activate audio session: \(error.localizedDescription)")
    }
  }

  /// Deactivates the audio session, allowing other audio apps to take over.
  func deactivate() {
    let audioSession = AVAudioSession.sharedInstance()
    do {
      try audioSession.setActive(false, options: .notifyOthersOnDeactivation)
      isActive = false
    } catch {
      print("[AudioSessionManager] Failed to deactivate audio session: \(error.localizedDescription)")
    }
  }
}
