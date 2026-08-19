import AVFoundation
import Foundation
import Observation
import OSLog

/// Plays one authored audio recording at a time for every rendered entry.
///
/// Playback state deliberately does not live in `AudioContentView`. Entries are
/// rendered inside lazy containers, so a card scrolled off screen loses its own
/// state and would cut its recording off mid-sentence. Routing every card
/// through one player also gives the tree its "one recording at a time"
/// behavior: starting a card stops whichever card was already playing.
@MainActor
@Observable
final class AudioContentPlayer {

  static let shared = AudioContentPlayer()

  /// The recording currently producing sound, or `nil` while nothing plays.
  private(set) var playingFileURL: URL?

  @ObservationIgnored private var player: AVAudioPlayer?
  @ObservationIgnored private var monitorTask: Task<Void, Never>?
  @ObservationIgnored private let log = Logger(
    subsystem: "app.muukii.journal",
    category: "AudioContentPlayer"
  )

  private init() {}

  func isPlaying(_ fileURL: URL) -> Bool {
    playingFileURL == fileURL
  }

  /// Starts `fileURL`, or stops it when it is the recording already playing.
  func toggle(fileURL: URL) {
    if isPlaying(fileURL) {
      stop()
    } else {
      play(fileURL: fileURL)
    }
  }

  func play(fileURL: URL) {
    stop()

    do {
      activateAudioSession()

      let player = try AVAudioPlayer(contentsOf: fileURL)
      guard player.play() else {
        log.error(
          "Couldn't start playback for \(fileURL.lastPathComponent, privacy: .public)"
        )
        resignAudioSession()
        return
      }

      self.player = player
      playingFileURL = fileURL
      startPlaybackMonitor()
    } catch {
      log.error(
        "Couldn't open recording: \(error.localizedDescription, privacy: .public)"
      )
      resignAudioSession()
    }
  }

  func stop() {
    guard playingFileURL != nil else { return }

    monitorTask?.cancel()
    monitorTask = nil
    player?.stop()
    player = nil
    playingFileURL = nil
    resignAudioSession()
  }

  /// Ends playback as soon as the player itself stops producing sound.
  ///
  /// Watching the player covers every way a recording can end through one path
  /// — reaching its last sample, a call or Siri interrupting the session, or the
  /// app being suspended in the background — so the published state never
  /// claims a recording is playing after the sound has stopped.
  private func startPlaybackMonitor() {
    monitorTask?.cancel()
    monitorTask = Task { [weak self] in
      while Task.isCancelled == false {
        try? await Task.sleep(for: .milliseconds(100))

        guard let self, Task.isCancelled == false else {
          return
        }
        guard player?.isPlaying == false else {
          continue
        }

        stop()
        return
      }
    }
  }

  /// Borrows the session for spoken content.
  ///
  /// A voice recording stays audible with the ring switch silenced, and ducks
  /// whatever is already playing instead of stopping it. The session is handed
  /// back when playback ends, so muted inline video previews go back to sharing
  /// it with the user's music.
  private func activateAudioSession() {
    #if os(iOS)
      do {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
          .playback,
          mode: .spokenAudio,
          options: [.duckOthers]
        )
        try session.setActive(true)
      } catch {
        log.error(
          "Couldn't activate the playback session: \(error.localizedDescription, privacy: .public)"
        )
      }
    #endif
  }

  private func resignAudioSession() {
    #if os(iOS)
      VideoPlaybackAudioSessionPolicy.restoreMutedInlinePlayback()
    #endif
  }
}
