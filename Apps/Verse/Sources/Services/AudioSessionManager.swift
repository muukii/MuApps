//
//  AudioSessionManager.swift
//  YouTubeSubtitle
//
//  Created by Claude on 2025/12/05.
//

import AVFoundation

/// Manages AVAudioSession configuration for the app.
/// Configures audio session to allow video playback even when device is in silent mode.
@Observable
final class AudioSessionManager: Sendable {
  static let shared = AudioSessionManager()

  private(set) var isConfigured: Bool = false
  private(set) var configurationError: (any Error)?

  private init() {
    configureAudioSession()
  }

  private func configureAudioSession() {
    let audioSession = AVAudioSession.sharedInstance()

    do {
      try audioSession.setCategory(
        .playback,
        mode: .moviePlayback,
        options: [
          .mixWithOthers
        ]
      )

      // Activate the audio session
      // .notifyOthersOnDeactivation: Allows other audio apps to resume when this app stops
      try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

      isConfigured = true
      print("[AudioSessionManager] Audio session configured successfully")
    } catch {
      configurationError = error
      print("[AudioSessionManager] Failed to configure audio session: \(error.localizedDescription)")
    }
  }
}
