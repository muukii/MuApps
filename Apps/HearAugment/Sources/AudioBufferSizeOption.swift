import AVFoundation
import Foundation

nonisolated enum AudioBufferSizeOption: Int, CaseIterable, Identifiable, Codable, Hashable, Sendable {
  case lowLatency = 128
  case balanced = 256
  case stable = 512
  case extraStable = 1024

  var id: Int {
    rawValue
  }

  var frameCount: AVAudioFrameCount {
    AVAudioFrameCount(rawValue)
  }

  var title: String {
    switch self {
    case .lowLatency:
      return "128"
    case .balanced:
      return "256"
    case .stable:
      return "512"
    case .extraStable:
      return "1024"
    }
  }

  var subtitle: String {
    switch self {
    case .lowLatency:
      return "Lowest latency"
    case .balanced:
      return "Balanced"
    case .stable:
      return "Stable"
    case .extraStable:
      return "Most stable"
    }
  }

  var maximumFrameCount: Int {
    max(rawValue * 4, 4_096)
  }

  func preferredDuration(sampleRate: Double) -> TimeInterval {
    Double(rawValue) / max(sampleRate, 1)
  }

  func latencyText(sampleRate: Double) -> String {
    let milliseconds = preferredDuration(sampleRate: sampleRate) * 1_000
    return String(format: "%.1f ms @ %.0f Hz", milliseconds, sampleRate)
  }
}
