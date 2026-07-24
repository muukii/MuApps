//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import AVFoundation
import BrightroomParametric
import Foundation

/// Owns the preview `AVPlayer` and rebuilds its video composition from the
/// current `EditingDocument` (the same `ParametricVideoRenderer` used for export,
/// so the preview is WYSIWYG with the output).
@MainActor
@Observable
final class VideoPreviewModel {

  let player = AVPlayer()

  private var loadedURL: URL?
  // Mutated only on the main actor; read in the nonisolated deinit after the
  // last reference is gone, so unsynchronized access is safe.
  @ObservationIgnored
  nonisolated(unsafe) private var endObserver: (any NSObjectProtocol)?

  init() {
    player.actionAtItemEnd = .none
  }

  deinit {
    if let endObserver {
      NotificationCenter.default.removeObserver(endObserver)
    }
  }

  /// Loads a video, replacing the current item and looping playback.
  func load(_ source: VideoSource) {
    guard loadedURL != source.url else { return }
    loadedURL = source.url

    let item = AVPlayerItem(asset: source.asset)
    player.replaceCurrentItem(with: item)
    observeEnd(of: item)
    player.play()
  }

  /// Rebuilds the live video composition for the current document.
  func apply(document: EditingDocument, for source: VideoSource, colorInfo: VideoColorInfo?) {
    guard let item = player.currentItem else { return }
    do {
      let composition = try ParametricVideoRenderer().makeVideoComposition(
        for: source.asset,
        document: document,
        renderSizeMode: .source,
        ciContext: BrightroomVideoCIContext.shared
      )
      (colorInfo ?? .sdrRec709).apply(to: composition)
      item.videoComposition = composition
    } catch {
      item.videoComposition = nil
    }
  }

  func play() { player.play() }
  func pause() { player.pause() }

  private func observeEnd(of item: AVPlayerItem) {
    if let endObserver {
      NotificationCenter.default.removeObserver(endObserver)
    }
    endObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime,
      object: item,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        self?.player.seek(to: .zero)
        self?.player.play()
      }
    }
  }
}
