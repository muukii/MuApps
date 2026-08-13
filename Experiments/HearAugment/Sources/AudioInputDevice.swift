import Foundation
@preconcurrency import AVFoundation

/// A user-facing microphone option backed by an `AVAudioSession` input port.
///
/// HearAugment currently exposes only the on-device microphone to preserve the
/// intended stereo capture path while headphones and AirPods remain
/// playback-only routes.
struct AudioInputDevice: Identifiable, Hashable {
  let id: String
  let name: String
  let detail: String

  init(port: AVAudioSessionPortDescription) {
    id = port.uid

    name = {
      switch port.portType {
      case .builtInMic:
        return "Device Microphone"
      default:
        return port.portName
      }
    }()

    detail = {
      switch port.portType {
      case .builtInMic:
        return "Built-in input"
      default:
        return port.portType.rawValue
      }
    }()
  }
}
