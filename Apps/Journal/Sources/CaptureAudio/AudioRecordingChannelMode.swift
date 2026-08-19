import AVFoundation

/// The channel layout requested for one recording take.
///
/// Stereo capture exists only for microphones that expose front/back data
/// sources whose supported polar patterns include `.stereo` — in practice the
/// iPhone built-in microphone array on a physical device. Every other input
/// (AirPods HFP, wired headsets, the Simulator) records mono.
enum AudioRecordingChannelMode: Equatable, Hashable, Sendable {
  case mono
  case stereoFront
  case stereoBack

  var channelCount: Int {
    switch self {
    case .mono:
      return 1
    case .stereoFront, .stereoBack:
      return 2
    }
  }
}

/// Pure fallback rule shared by the recorder state and focused tests.
enum AudioRecordingChannelModePolicy {

  /// Keeps an explicit stereo choice only while the resolved input supports it.
  /// Anything else records mono rather than failing the take.
  static func effectiveMode(
    for selection: AudioRecordingChannelMode,
    supportedModes: [AudioRecordingChannelMode]
  ) -> AudioRecordingChannelMode {
    supportedModes.contains(selection) ? selection : .mono
  }
}

#if os(iOS)
  extension AudioRecordingChannelMode {

    /// The built-in microphone data source this mode records through.
    /// Mono uses the system default data source instead of requesting one.
    var dataSourceOrientation: AVAudioSession.Orientation? {
      switch self {
      case .mono:
        return nil
      case .stereoFront:
        return .front
      case .stereoBack:
        return .back
      }
    }
  }
#endif
