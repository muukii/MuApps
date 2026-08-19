import AVFoundation

/// A microphone that Tinycurve can use for an audio recording.
///
/// The value intentionally copies only stable display and selection data from
/// `AVAudioSessionPortDescription`. This keeps AVFoundation reference objects
/// out of SwiftUI state and makes routing policy independently testable.
struct AudioRecordingInput: Identifiable, Equatable, Hashable, Sendable {

  /// The broad connection class used by Tinycurve's automatic-input policy.
  enum Kind: Equatable, Hashable, Sendable {
    case builtIn
    case wired
    case wireless
    case other
  }

  /// Stable system identifier used to resolve the port again before recording.
  let id: String

  /// System-provided, user-facing device name such as “iPhone Microphone” or
  /// the name of a paired AirPods device.
  let name: String

  /// Connection class used for automatic preference and safe fallback.
  let kind: Kind

  /// Channel modes this microphone can record, `.mono` always first. Stereo
  /// entries exist only when a data source advertises the `.stereo` polar
  /// pattern, which the Simulator and non-built-in microphones never do.
  let supportedChannelModes: [AudioRecordingChannelMode]

  init(
    id: String,
    name: String,
    kind: Kind,
    supportedChannelModes: [AudioRecordingChannelMode] = [.mono]
  ) {
    self.id = id
    self.name = name
    self.kind = kind
    self.supportedChannelModes = supportedChannelModes
  }
}

/// The user's transient microphone choice for one recorder presentation.
enum AudioRecordingInputSelection: Equatable, Hashable, Sendable {
  /// Tinycurve follows available hardware and prefers a wireless microphone.
  case automatic

  /// Tinycurve requests one currently available system input by stable ID.
  case input(id: AudioRecordingInput.ID)
}

/// Pure routing rules shared by the live audio session and focused tests.
enum AudioRecordingInputSelectionPolicy {

  /// Resolves the effective input for a selection and the currently routed port.
  static func resolvedInput(
    for selection: AudioRecordingInputSelection,
    availableInputs: [AudioRecordingInput],
    currentInputID: AudioRecordingInput.ID?
  ) -> AudioRecordingInput? {
    switch selection {
    case .automatic:
      return automaticInput(
        availableInputs: availableInputs,
        currentInputID: currentInputID
      )
    case .input(let id):
      return availableInputs.first { $0.id == id }
        ?? automaticInput(
          availableInputs: availableInputs,
          currentInputID: currentInputID
        )
    }
  }

  /// Prefers an already-routed wireless microphone, then another available
  /// wireless microphone. Without one, the valid current route is preserved
  /// before falling back to the built-in microphone or the first available port.
  private static func automaticInput(
    availableInputs: [AudioRecordingInput],
    currentInputID: AudioRecordingInput.ID?
  ) -> AudioRecordingInput? {
    let currentInput = availableInputs.first { $0.id == currentInputID }

    if currentInput?.kind == .wireless {
      return currentInput
    }
    if let wirelessInput = availableInputs.first(where: { $0.kind == .wireless }) {
      return wirelessInput
    }
    if let currentInput {
      return currentInput
    }
    return availableInputs.first(where: { $0.kind == .builtIn })
      ?? availableInputs.first
  }
}

#if os(iOS)
  extension AudioRecordingInput {

    /// Copies a live AVFoundation port into the value model used by CaptureAudio.
    init(port: AVAudioSessionPortDescription) {
      self.init(
        id: port.uid,
        name: port.portName,
        kind: Self.kind(for: port.portType),
        supportedChannelModes: Self.supportedChannelModes(for: port)
      )
    }

    private static func supportedChannelModes(
      for port: AVAudioSessionPortDescription
    ) -> [AudioRecordingChannelMode] {
      var modes: [AudioRecordingChannelMode] = [.mono]
      for dataSource in port.dataSources ?? [] {
        guard dataSource.supportedPolarPatterns?.contains(.stereo) == true else {
          continue
        }
        if dataSource.orientation == .front, modes.contains(.stereoFront) == false {
          modes.append(.stereoFront)
        }
        if dataSource.orientation == .back, modes.contains(.stereoBack) == false {
          modes.append(.stereoBack)
        }
      }
      return modes
    }

    private static func kind(for portType: AVAudioSession.Port) -> Kind {
      switch portType {
      case .builtInMic:
        return .builtIn
      case .bluetoothHFP, .bluetoothLE:
        // A2DP is intentionally absent: it is an output profile and cannot be a
        // recording input. AirPods microphones arrive through Bluetooth HFP.
        return .wireless
      case .headsetMic, .lineIn, .usbAudio:
        return .wired
      default:
        return .other
      }
    }
  }
#endif
