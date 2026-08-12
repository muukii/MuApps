import Testing

@testable import Verse

@Suite("Step Mode subtitle boundary stopping")
struct StepModeStopStateTests {
  private let cueA = Subtitle.Cue(
    id: 1,
    startTime: 10,
    endTime: 12,
    text: "Cue A"
  )
  private let cueB = Subtitle.Cue(
    id: 2,
    startTime: 13,
    endTime: 15,
    text: "Cue B"
  )

  @Test
  func seekingBeforeConsumedBoundaryRearmsTheSameCue() {
    var state = StepModeStopState()
    state.recordStop(at: cueA)

    #expect(state.isStopEligible(for: cueA) == false)

    state.handleSeek(to: cueA.startTime)

    #expect(state.isStopEligible(for: cueA))
  }

  @Test
  func resumingWithoutSeekingKeepsTheConsumedBoundarySuppressed() {
    var state = StepModeStopState()
    state.recordStop(at: cueA)

    #expect(state.isStopEligible(for: cueA) == false)
  }

  @Test
  func seekingForwardKeepsTheConsumedBoundaryButAllowsTheDestinationCue() {
    var state = StepModeStopState()
    state.recordStop(at: cueA)

    state.handleSeek(to: cueB.startTime)

    #expect(state.isStopEligible(for: cueA) == false)
    #expect(state.isStopEligible(for: cueB))
  }

  @Test
  func seekingToTheConsumedBoundaryDoesNotRearmIt() {
    var state = StepModeStopState()
    state.recordStop(at: cueA)

    state.handleSeek(to: cueA.endTime)

    #expect(state.isStopEligible(for: cueA) == false)
  }

  @Test
  func changingTheCueSequenceClearsTheConsumedBoundary() {
    var state = StepModeStopState()
    state.recordStop(at: cueA)

    state.reset()

    #expect(state.isStopEligible(for: cueA))
  }
}
