import AVFoundation

/// App-wide audio session policy for muted inline video previews.
///
/// Tinycurve treats authored videos as silent visual previews. The app configures the
/// process audio session once at launch so those previews mix with music or
/// podcasts already playing outside the app, instead of toggling the session as
/// each scrolling cell appears and disappears.
@MainActor
enum VideoPlaybackAudioSessionPolicy {

  private static var isConfigured = false

  /// Sets the audio category used by Journal video previews.
  ///
  /// This intentionally avoids `setActive(_:)`: playback objects can manage
  /// activation when needed, while the scroll lifecycle never performs a
  /// blocking audio-session deactivate.
  static func configureForMutedInlinePlayback() {
    guard isConfigured == false else { return }
    isConfigured = true

    #if os(iOS)
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
    #endif
  }
}
