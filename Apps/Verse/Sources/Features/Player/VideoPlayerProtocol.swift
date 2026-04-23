//
//  VideoPlayerProtocol.swift
//  YouTubeSubtitle
//
//  Created by Claude on 2025/12/05.
//

import AVFoundation
import Foundation
import SwiftUI

/// Protocol for video player controllers.
/// Controllers manage playback state and are passed to their corresponding View.
@MainActor
protocol VideoPlayerController: AnyObject {

  // MARK: - Playback State

  /// Whether the video is currently playing
  var isPlaying: Bool { get }

  /// Current playback time in seconds
  var currentTime: Double { get async }

  /// Total duration of the video in seconds
  var duration: Double { get async }

  /// Current playback rate (1.0 = normal speed)
  var playbackRate: Double { get }

  // MARK: - Playback Control

  /// Start or resume playback
  func play() async

  /// Pause playback
  func pause() async

  /// Seek to specified time in seconds
  func seek(to time: Double) async

  /// Set playback rate
  func setPlaybackRate(_ rate: Double) async
}
