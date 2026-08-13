import AVFoundation
import Foundation

nonisolated struct AudioBufferSizeOption: Sendable, Identifiable, Hashable {
  let frameCount: AVAudioFrameCount
  let title: String
  let subtitle: String

  var id: AVAudioFrameCount { frameCount }

  var maximumFrameCount: Int {
    max(Int(frameCount) * 4, 4_096)
  }

  func preferredDuration(sampleRate: Double) -> TimeInterval {
    Double(frameCount) / max(sampleRate, 1)
  }

  func latencyText(sampleRate: Double) -> String {
    let milliseconds = preferredDuration(sampleRate: sampleRate) * 1_000
    return String(format: "%.1f ms @ %.0f Hz", milliseconds, sampleRate)
  }
}

nonisolated extension AudioBufferSizeOption {
  static let lowLatency = AudioBufferSizeOption(
    frameCount: 128,
    title: "128",
    subtitle: "Lowest latency"
  )

  static let balanced = AudioBufferSizeOption(
    frameCount: 256,
    title: "256",
    subtitle: "Balanced"
  )

  static let stable = AudioBufferSizeOption(
    frameCount: 512,
    title: "512",
    subtitle: "Stable"
  )

  static let extraStable = AudioBufferSizeOption(
    frameCount: 1024,
    title: "1024",
    subtitle: "Most stable"
  )

  static let allCases: [AudioBufferSizeOption] = [
    .lowLatency, .balanced, .stable, .extraStable,
  ]

  static func with(frameCount: AVAudioFrameCount) -> AudioBufferSizeOption? {
    allCases.first(where: { $0.frameCount == frameCount })
  }
}
