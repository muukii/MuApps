import CoreGraphics
import Foundation
import Testing

@testable import CaptureAudio

struct LiveWaveformCanvasLayoutTests {

  @Test
  func liveMeterSnapshotRetainsOutgoingAndIncomingSamplesForOneTransition() {
    let date = Date(timeIntervalSinceReferenceDate: 100)
    let resting = LiveAudioMeterSnapshot.resting(sampleCount: 4)

    let snapshot = resting.appending(1, at: date)

    #expect(snapshot.samples == [0, 0, 0, 1])
    #expect(snapshot.renderingSamples == [0, 0, 0, 0, 1])
    #expect(snapshot.newestSampleDate == date)
  }

  @Test
  func scrollPhaseClampsBeforeAndAfterOneSampleInterval() {
    let sampledAt = Date(timeIntervalSinceReferenceDate: 100)

    #expect(
      LiveWaveformCanvasLayout.scrollPhase(
        at: sampledAt.addingTimeInterval(-1),
        newestSampleDate: sampledAt,
        sampleInterval: 0.05
      ) == 0
    )
    #expect(
      abs(
        LiveWaveformCanvasLayout.scrollPhase(
          at: sampledAt.addingTimeInterval(0.025),
          newestSampleDate: sampledAt,
          sampleInterval: 0.05
        ) - 0.5
      ) < 0.000_1
    )
    #expect(
      LiveWaveformCanvasLayout.scrollPhase(
        at: sampledAt.addingTimeInterval(1),
        newestSampleDate: sampledAt,
        sampleInterval: 0.05
      ) == 1
    )
  }

  @Test
  func layoutMovesOutgoingAndIncomingBarsAcrossOneVisibleSlot() {
    let start = LiveWaveformCanvasLayout(
      size: CGSize(width: 52, height: 24),
      visibleBarCount: 4,
      phase: 0,
      barSpacing: 4,
      minimumBarHeight: 4
    )
    let end = LiveWaveformCanvasLayout(
      size: CGSize(width: 52, height: 24),
      visibleBarCount: 4,
      phase: 1,
      barSpacing: 4,
      minimumBarHeight: 4
    )

    #expect(start.barWidth == 10)
    #expect(start.barStride == 14)
    #expect(start.barRect(for: 0, at: 0) == CGRect(x: 0, y: 10, width: 10, height: 4))
    #expect(start.barRect(for: 1, at: 4) == CGRect(x: 56, y: 0, width: 10, height: 24))
    #expect(end.barRect(for: 0, at: 0) == CGRect(x: -14, y: 10, width: 10, height: 4))
    #expect(end.barRect(for: 1, at: 4) == CGRect(x: 42, y: 0, width: 10, height: 24))
  }
}
