//
//  AudioSessionManager.swift
//  YouTubeSubtitle
//
//  Created by Claude on 2025/12/05.
//

#if os(iOS)
import AVFoundation
#endif
import Observation

/// Manages platform audio configuration for the app.
/// On iOS, configures AVAudioSession to allow video playback even when device is in silent mode.
@Observable
final class AudioSessionManager: Sendable {
  static let shared = AudioSessionManager()

  private(set) var isConfigured: Bool = false
  private(set) var configurationError: (any Error)?

  private init() {
    configureAudioSession()
  }

  private func configureAudioSession() {
#if os(iOS)
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
#else
    isConfigured = true
#endif
  }
}
