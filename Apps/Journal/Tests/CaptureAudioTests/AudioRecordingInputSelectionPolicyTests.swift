import Testing

@testable import CaptureAudio

struct AudioRecordingInputSelectionPolicyTests {

  @Test
  func automaticSelectionPrefersWirelessOverCurrentBuiltInInput() {
    let builtIn = input(id: "built-in", kind: .builtIn)
    let airPods = input(id: "airpods", kind: .wireless)

    let resolved = AudioRecordingInputSelectionPolicy.resolvedInput(
      for: .automatic,
      availableInputs: [builtIn, airPods],
      currentInputID: builtIn.id
    )

    #expect(resolved == airPods)
  }

  @Test
  func automaticSelectionKeepsCurrentWirelessInput() {
    let firstWireless = input(id: "wireless-1", kind: .wireless)
    let currentWireless = input(id: "wireless-2", kind: .wireless)

    let resolved = AudioRecordingInputSelectionPolicy.resolvedInput(
      for: .automatic,
      availableInputs: [firstWireless, currentWireless],
      currentInputID: currentWireless.id
    )

    #expect(resolved == currentWireless)
  }

  @Test
  func automaticSelectionKeepsValidCurrentInputWithoutWirelessHardware() {
    let builtIn = input(id: "built-in", kind: .builtIn)
    let wired = input(id: "wired", kind: .wired)

    let resolved = AudioRecordingInputSelectionPolicy.resolvedInput(
      for: .automatic,
      availableInputs: [builtIn, wired],
      currentInputID: wired.id
    )

    #expect(resolved == wired)
  }

  @Test
  func unavailableExplicitSelectionFallsBackToAutomaticPolicy() {
    let builtIn = input(id: "built-in", kind: .builtIn)
    let airPods = input(id: "airpods", kind: .wireless)

    let resolved = AudioRecordingInputSelectionPolicy.resolvedInput(
      for: .input(id: "disconnected"),
      availableInputs: [builtIn, airPods],
      currentInputID: builtIn.id
    )

    #expect(resolved == airPods)
  }

  @Test
  func automaticSelectionUsesBuiltInInputWhenCurrentRouteDisappears() {
    let external = input(id: "external", kind: .other)
    let builtIn = input(id: "built-in", kind: .builtIn)

    let resolved = AudioRecordingInputSelectionPolicy.resolvedInput(
      for: .automatic,
      availableInputs: [external, builtIn],
      currentInputID: "disconnected"
    )

    #expect(resolved == builtIn)
  }

  private func input(
    id: AudioRecordingInput.ID,
    kind: AudioRecordingInput.Kind
  ) -> AudioRecordingInput {
    AudioRecordingInput(id: id, name: id, kind: kind)
  }
}
