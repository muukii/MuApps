//
//  LocalVideoPlayer.swift
//  YouTubeSubtitle
//
//  Created by Claude on 2025/12/05.
//

import AVFoundation
import AVKit
import Foundation
import SwiftUI

// MARK: - LocalVideoPlayer

/// SwiftUI View for local video playback using AVPlayer.
/// Usage: LocalVideoPlayer(controller: controller)
struct LocalVideoPlayer: View {
  let controller: LocalVideoPlayerController

  var body: some View {
    VideoPlayer(player: controller.player)
      .onAppear {
        print("[LocalVideoPlayer] VideoPlayer appeared, status: \(controller.playerStatus.rawValue)")
      }
  }
}

// MARK: - LocalVideoPlayerController

/// Controller for local video playback using AVPlayer.
/// Conforms to VideoPlayerController protocol for unified playback control.
@Observable
@MainActor
final class LocalVideoPlayerController: VideoPlayerController, Sendable {

  // MARK: - Properties

  let player: AVPlayer
  private var _playbackRate: Double = 1.0
  private var statusObservation: NSKeyValueObservation?
  private var errorObservation: NSKeyValueObservation?

  private(set) var playerStatus: AVPlayerItem.Status = .unknown
  private(set) var playerError: Error?

  // MARK: - Initialization

  init(url: URL) {
    let asset = AVURLAsset(url: url)
    let playerItem = AVPlayerItem(asset: asset)
    self.player = AVPlayer(playerItem: playerItem)

    // Log the URL being played
    print("[LocalVideoPlayerController] Initializing with URL: \(url.path)")
    print("[LocalVideoPlayerController] URL scheme: \(url.scheme ?? "nil")")
    print("[LocalVideoPlayerController] File exists: \(FileManager.default.fileExists(atPath: url.path))")

    // Check file attributes
    if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) {
      let fileSize = attributes[.size] as? Int64 ?? 0
      print("[LocalVideoPlayerController] File size: \(fileSize) bytes")
    }

    // Check file magic bytes to verify actual file format
    if let fileHandle = try? FileHandle(forReadingFrom: url) {
      let headerData = fileHandle.readData(ofLength: 32)
      let hexString = headerData.map { String(format: "%02X", $0) }.joined(separator: " ")
      print("[LocalVideoPlayerController] File header (hex): \(hexString)")

      // Check for common formats
      if let headerString = String(data: headerData, encoding: .utf8) {
        if headerString.contains("<!DOCTYPE") || headerString.contains("<html") {
          print("[LocalVideoPlayerController] ⚠️ WARNING: File appears to be HTML, not video!")
        }
      }

      // Check for MP4 (ftyp box)
      if headerData.count >= 8 {
        let ftypSignature = headerData[4..<8]
        if String(data: ftypSignature, encoding: .ascii) == "ftyp" {
          print("[LocalVideoPlayerController] ✓ File format: MP4 (ftyp detected)")
        }
      }

      // Check for WebM (EBML header: 1A 45 DF A3)
      if headerData.count >= 4 {
        let webmSignature: [UInt8] = [0x1A, 0x45, 0xDF, 0xA3]
        let firstFour = Array(headerData.prefix(4))
        if firstFour == webmSignature {
          print("[LocalVideoPlayerController] ⚠️ File format: WebM (not supported by AVPlayer)")
        }
      }

      try? fileHandle.close()
    }

    // Load asset tracks asynchronously for debugging
    Task {
      do {
        let tracks = try await asset.load(.tracks)
        print("[LocalVideoPlayerController] Asset tracks count: \(tracks.count)")
        for track in tracks {
          print("[LocalVideoPlayerController] Track mediaType: \(track.mediaType.rawValue)")
        }

        let isPlayable = try await asset.load(.isPlayable)
        print("[LocalVideoPlayerController] Asset isPlayable: \(isPlayable)")

        let duration = try await asset.load(.duration)
        print("[LocalVideoPlayerController] Asset duration: \(duration.seconds) seconds")
      } catch {
        print("[LocalVideoPlayerController] Failed to load asset info: \(error)")
        if let nsError = error as NSError? {
          print("[LocalVideoPlayerController] Error domain: \(nsError.domain), code: \(nsError.code)")
          print("[LocalVideoPlayerController] Error userInfo: \(nsError.userInfo)")
        }
      }
    }

    // Observe player item status
    statusObservation = playerItem.observe(\.status, options: [.new]) { [weak self] item, _ in
      Task { @MainActor in
        self?.playerStatus = item.status
        print("[LocalVideoPlayerController] Player item status changed: \(item.status.rawValue)")
        if item.status == .failed {
          self?.playerError = item.error
          if let error = item.error {
            print("[LocalVideoPlayerController] Player item failed: \(error.localizedDescription)")
            if let nsError = error as NSError? {
              print("[LocalVideoPlayerController] Error domain: \(nsError.domain), code: \(nsError.code)")
              print("[LocalVideoPlayerController] Error userInfo: \(nsError.userInfo)")
            }
          }
        } else if item.status == .readyToPlay {
          print("[LocalVideoPlayerController] Player item ready to play")
        }
      }
    }

    // Observe player item error
    errorObservation = playerItem.observe(\.error, options: [.new]) { [weak self] item, _ in
      Task { @MainActor in
        if let error = item.error {
          self?.playerError = error
          print("[LocalVideoPlayerController] Player item error: \(error.localizedDescription)")
        }
      }
    }
  }

  isolated deinit {
    statusObservation?.invalidate()
    errorObservation?.invalidate()
  }

  // MARK: - VideoPlayerController

  var isPlaying: Bool {
    player.timeControlStatus == .playing
  }

  var currentTime: Double {
    get async {
      let time = player.currentTime()
      guard time.isValid && !time.isIndefinite else { return 0 }
      return time.seconds
    }
  }

  var duration: Double {
    get async {
      guard let item = player.currentItem else { return 0 }

      // Wait for item to be ready
      if item.status != .readyToPlay {
        // Try to load duration from asset
        if let asset = player.currentItem?.asset {
          do {
            let duration = try await asset.load(.duration)
            if duration.isValid && !duration.isIndefinite {
              return duration.seconds
            }
          } catch {
            print("[LocalVideoPlayerController] Failed to load duration: \(error)")
          }
        }
        return 0
      }

      let duration = item.duration
      if duration.isValid && !duration.isIndefinite {
        return duration.seconds
      }

      return 0
    }
  }

  var playbackRate: Double {
    _playbackRate
  }

  func play() async {
    guard playerStatus == .readyToPlay else {
      print("[LocalVideoPlayerController] Cannot play - status: \(playerStatus.rawValue)")
      return
    }
    player.rate = Float(_playbackRate)
  }

  func pause() async {
    player.pause()
  }

  func seek(to time: Double) async {
    let cmTime = CMTime(seconds: time, preferredTimescale: 600)
    await player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
  }

  func setPlaybackRate(_ rate: Double) async {
    _playbackRate = rate
    if isPlaying {
      player.rate = Float(rate)
    }
  }
}
