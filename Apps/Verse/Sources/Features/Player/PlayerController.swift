//
//  PlayerController.swift
//  YouTubeSubtitle
//
//  Created by Claude Code
//

import Foundation

// MARK: - Player Controller Enum

/// Type-safe wrapper that holds either YouTube or local video player controller.
/// This approach avoids existential type issues with protocols.
enum PlayerController {
  case youtube(YouTubeVideoPlayerController)
  case local(LocalVideoPlayerController)

  // MARK: - VideoPlayerController Forwarding

  var isPlaying: Bool {
    switch self {
    case .youtube(let controller): controller.isPlaying
    case .local(let controller): controller.isPlaying
    }
  }

  /// Whether the player is ready (priming complete for YouTube, always true for local)
  var isReady: Bool {
    switch self {
    case .youtube(let controller): controller.isReady
    case .local: true
    }
  }

  var currentTime: Double {
    get async {
      switch self {
      case .youtube(let controller): await controller.currentTime
      case .local(let controller): await controller.currentTime
      }
    }
  }

  var duration: Double {
    get async {
      switch self {
      case .youtube(let controller): await controller.duration
      case .local(let controller): await controller.duration
      }
    }
  }

  var playbackRate: Double {
    switch self {
    case .youtube(let controller): controller.playbackRate
    case .local(let controller): controller.playbackRate
    }
  }

  func play() async {
    switch self {
    case .youtube(let controller): await controller.play()
    case .local(let controller): await controller.play()
    }
  }

  func pause() async {
    switch self {
    case .youtube(let controller): await controller.pause()
    case .local(let controller): await controller.pause()
    }
  }

  func seek(to time: Double) async {
    switch self {
    case .youtube(let controller): await controller.seek(to: time)
    case .local(let controller): await controller.seek(to: time)
    }
  }

  func setPlaybackRate(_ rate: Double) async {
    switch self {
    case .youtube(let controller): await controller.setPlaybackRate(rate)
    case .local(let controller): await controller.setPlaybackRate(rate)
    }
  }
}
