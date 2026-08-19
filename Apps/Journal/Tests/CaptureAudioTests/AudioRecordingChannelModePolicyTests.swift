import Testing

@testable import CaptureAudio

struct AudioRecordingChannelModePolicyTests {

  @Test
  func stereoSelectionSurvivesOnSupportingInput() {
    let effective = AudioRecordingChannelModePolicy.effectiveMode(
      for: .stereoBack,
      supportedModes: [.mono, .stereoFront, .stereoBack]
    )

    #expect(effective == .stereoBack)
  }

  @Test
  func stereoSelectionFallsBackToMonoOnUnsupportedInput() {
    let effective = AudioRecordingChannelModePolicy.effectiveMode(
      for: .stereoFront,
      supportedModes: [.mono]
    )

    #expect(effective == .mono)
  }

  @Test
  func monoSelectionIsAlwaysEffective() {
    let effective = AudioRecordingChannelModePolicy.effectiveMode(
      for: .mono,
      supportedModes: [.mono, .stereoFront, .stereoBack]
    )

    #expect(effective == .mono)
  }

  @Test
  func inputSupportsOnlyMonoByDefault() {
    let input = AudioRecordingInput(id: "built-in", name: "built-in", kind: .builtIn)

    #expect(input.supportedChannelModes == [.mono])
  }

  @Test
  func stereoChannelModesRecordTwoChannels() {
    #expect(AudioRecordingChannelMode.mono.channelCount == 1)
    #expect(AudioRecordingChannelMode.stereoFront.channelCount == 2)
    #expect(AudioRecordingChannelMode.stereoBack.channelCount == 2)
  }
}
