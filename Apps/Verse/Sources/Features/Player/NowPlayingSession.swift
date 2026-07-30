//
//  NowPlayingSession.swift
//  YouTubeSubtitle
//

import MediaPlayer
import UIKit

/// Publishes playback metadata to the system Now Playing center (Lock Screen,
/// Control Center) and receives remote commands while local media plays.
///
/// Only local (downloaded / imported) playback runs a session. YouTube
/// streaming pauses when the app leaves the foreground, so system playback
/// controls would offer commands that cannot work there.
@MainActor
final class NowPlayingSession {

  // MARK: - Types

  struct Metadata {
    let title: String
    let artist: String?
    let isAudioOnly: Bool
    let thumbnailURL: URL?
  }

  struct Handlers {
    let onPlay: @MainActor @Sendable () -> Void
    let onPause: @MainActor @Sendable () -> Void
    let onTogglePlayPause: @MainActor @Sendable () -> Void
    let onSkipBackward: @MainActor @Sendable (TimeInterval) -> Void
    let onSkipForward: @MainActor @Sendable (TimeInterval) -> Void
    let onSeek: @MainActor @Sendable (TimeInterval) -> Void
  }

  /// Interval shown on the Lock Screen skip buttons.
  static let skipInterval: TimeInterval = 10

  // MARK: - Properties

  private(set) var isActive: Bool = false
  private var commandTargets: [(command: MPRemoteCommand, token: Any)] = []
  private var artworkTask: Task<Void, Never>?

  // MARK: - Lifecycle

  isolated deinit {
    end()
  }

  /// Starts publishing to the system player UI and registers remote commands.
  func begin(metadata: Metadata, handlers: Handlers) {
    end()
    isActive = true

    do {
      let center = MPRemoteCommandCenter.shared()

      addTarget(to: center.playCommand) {
        handlers.onPlay()
      }
      addTarget(to: center.pauseCommand) {
        handlers.onPause()
      }
      addTarget(to: center.togglePlayPauseCommand) {
        handlers.onTogglePlayPause()
      }

      center.skipBackwardCommand.preferredIntervals = [NSNumber(value: Self.skipInterval)]
      let backwardToken = center.skipBackwardCommand.addTarget { event in
        let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? Self.skipInterval
        Task { @MainActor in
          handlers.onSkipBackward(interval)
        }
        return .success
      }
      commandTargets.append((center.skipBackwardCommand, backwardToken))

      center.skipForwardCommand.preferredIntervals = [NSNumber(value: Self.skipInterval)]
      let forwardToken = center.skipForwardCommand.addTarget { event in
        let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? Self.skipInterval
        Task { @MainActor in
          handlers.onSkipForward(interval)
        }
        return .success
      }
      commandTargets.append((center.skipForwardCommand, forwardToken))

      let seekToken = center.changePlaybackPositionCommand.addTarget { event in
        guard let event = event as? MPChangePlaybackPositionCommandEvent else {
          return .commandFailed
        }
        let position = event.positionTime
        Task { @MainActor in
          handlers.onSeek(position)
        }
        return .success
      }
      commandTargets.append((center.changePlaybackPositionCommand, seekToken))
    }

    do {
      let mediaType: MPNowPlayingInfoMediaType = metadata.isAudioOnly ? .audio : .video

      var info: [String: Any] = [
        MPMediaItemPropertyTitle: metadata.title,
        MPNowPlayingInfoPropertyMediaType: mediaType.rawValue,
      ]
      if let artist = metadata.artist {
        info[MPMediaItemPropertyArtist] = artist
      }
      MPNowPlayingInfoCenter.default().nowPlayingInfo = info

      loadArtwork(from: metadata.thumbnailURL)
    }
  }

  /// Reflects the current playback timing on the system player UI.
  ///
  /// The system interpolates elapsed time from `rate`, so calling this on
  /// play / pause / seek / rate changes is sufficient — no periodic updates.
  func updatePlayback(duration: Double, elapsedTime: Double, rate: Double) {
    guard isActive else { return }
    var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
    info[MPMediaItemPropertyPlaybackDuration] = duration
    info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsedTime
    info[MPNowPlayingInfoPropertyPlaybackRate] = rate
    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
  }

  /// Stops publishing and unregisters all remote commands.
  func end() {
    guard isActive else { return }
    isActive = false

    artworkTask?.cancel()
    artworkTask = nil

    for entry in commandTargets {
      entry.command.removeTarget(entry.token)
    }
    commandTargets.removeAll()

    MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
  }

  // MARK: - Private

  private func addTarget(
    to command: MPRemoteCommand,
    action: @escaping @MainActor @Sendable () -> Void
  ) {
    let token = command.addTarget { _ in
      Task { @MainActor in
        action()
      }
      return .success
    }
    commandTargets.append((command, token))
  }

  private func loadArtwork(from url: URL?) {
    artworkTask?.cancel()
    guard let url else { return }

    artworkTask = Task { [weak self] in
      guard
        let (data, _) = try? await URLSession.shared.data(from: url),
        let image = UIImage(data: data)
      else { return }

      guard let self, self.isActive, !Task.isCancelled else { return }

      let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
      var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
      info[MPMediaItemPropertyArtwork] = artwork
      MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
  }
}
