//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import AVFoundation

/// App-wide audio-session policy for Färg video playback.
///
/// Färg keeps source-video audio audible while allowing music, podcasts, and
/// other audio from outside the app to continue. The category is configured
/// once at launch instead of being coupled to the preview player's lifecycle.
@MainActor
enum VideoPlaybackAudioSessionPolicy {

  /// Configures video playback to mix with audio from other apps.
  ///
  /// This intentionally avoids activating the session. `AVPlayer` activates it
  /// when playback begins, without Färg interrupting other audio at launch.
  static func configureForMixedPlayback() {
    do {
      try AVAudioSession.sharedInstance().setCategory(
        .playback,
        mode: .moviePlayback,
        options: [.mixWithOthers]
      )
    } catch {
      print(
        "[VideoPlaybackAudioSessionPolicy] Failed to configure audio session: \(error.localizedDescription)"
      )
    }
  }
}
