import AVFoundation
import CoreImage
import Foundation
import QuartzCore
import UIKit

protocol FrameSource: AnyObject, Sendable {
  /// Returns the next CIImage to display, or nil if not available yet.
  /// Implementations are expected to be called on the main thread.
  @MainActor func nextFrame() -> CIImage?

  /// Whether the source is animated and the view should free-run at the display refresh rate.
  nonisolated var isContinuous: Bool { get }
}

@MainActor
final class StillImageFrameSource: FrameSource {
  let image: CIImage
  let isContinuous = false

  init(image: CIImage) { self.image = image }

  init?(uiImage: UIImage) {
    guard let cg = uiImage.cgImage else { return nil }
    self.image = CIImage(cgImage: cg)
  }

  func nextFrame() -> CIImage? { image }
}

@MainActor
final class VideoFrameSource: FrameSource {
  let player: AVPlayer
  let output: AVPlayerItemVideoOutput
  let isContinuous = true

  private var lastFrame: CIImage?
  private var didStartPlayback = false
  nonisolated(unsafe) private var loopObserver: NSObjectProtocol?

  init(url: URL) {
    let asset = AVURLAsset(url: url)
    let item = AVPlayerItem(asset: asset)
    let attrs: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
      kCVPixelBufferIOSurfacePropertiesKey as String: [:] as NSDictionary,
    ]
    let output = AVPlayerItemVideoOutput(pixelBufferAttributes: attrs)
    item.add(output)
    self.player = AVPlayer(playerItem: item)
    self.output = output
    self.player.isMuted = true
    self.player.actionAtItemEnd = .none
    self.loopObserver = NotificationCenter.default.addObserver(
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

  deinit {
    if let loopObserver {
      NotificationCenter.default.removeObserver(loopObserver)
    }
  }

  func play() {
    didStartPlayback = true
    player.play()
  }

  func pause() {
    player.pause()
  }

  func nextFrame() -> CIImage? {
    if !didStartPlayback {
      didStartPlayback = true
      player.play()
    }
    let host = CACurrentMediaTime()
    let itemTime = output.itemTime(forHostTime: host)
    if output.hasNewPixelBuffer(forItemTime: itemTime),
       let buffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) {
      lastFrame = CIImage(cvPixelBuffer: buffer)
    }
    return lastFrame
  }
}
