import Foundation
@preconcurrency import AVFoundation

struct AudioInputDevice: Identifiable, Hashable {
  let id: String
  let name: String
  let detail: String
  let isBuiltIn: Bool
  let isBluetooth: Bool

  init(port: AVAudioSessionPortDescription) {
    id = port.uid
    name = Self.displayName(for: port)
    detail = Self.detail(for: port.portType)
    isBuiltIn = port.portType == .builtInMic
    isBluetooth = port.portType == .bluetoothHFP || port.portType == .bluetoothLE
  }

  private static func displayName(for port: AVAudioSessionPortDescription) -> String {
    if port.portType == .builtInMic {
      return "Device Microphone"
    }

    return port.portName
  }

  private static func detail(for portType: AVAudioSession.Port) -> String {
    switch portType {
    case .builtInMic:
      return "Built-in input"
    case .bluetoothHFP, .bluetoothLE:
      return "Bluetooth input"
    case .headsetMic:
      return "Headset input"
    case .usbAudio:
      return "USB input"
    case .lineIn:
      return "Line input"
    default:
      return portType.rawValue
    }
  }
}
