import Foundation
import Testing

@testable import AppUIComponents

struct AudioWaveformSampleTests {

  @Test
  func downsampledLevels_preservePeakFromEachTimeBucket() {
    let levels = Data([0, 64, 255, 32, 128, 16])

    let result = AudioWaveformSample.downsampledLevels(
      levels,
      maximumCount: 3
    )

    #expect(result == [64, 255, 128])
  }

  @Test
  func downsampledLevels_keepShortRecordingWithoutInventingBars() {
    let levels = Data([10, 20, 30])

    let result = AudioWaveformSample.downsampledLevels(
      levels,
      maximumCount: 16
    )

    #expect(result == [10, 20, 30])
  }

  @Test
  func samples_useLegacyFallbackWhenWaveformIsUnavailable() {
    let fallback = [AudioWaveformSample(id: 0, height: 42)]

    let missing = AudioWaveformSample.samples(
      from: nil,
      maximumCount: 16,
      heightRange: 12...70,
      fallback: fallback
    )
    let empty = AudioWaveformSample.samples(
      from: Data(),
      maximumCount: 16,
      heightRange: 12...70,
      fallback: fallback
    )

    #expect(missing == fallback)
    #expect(empty == fallback)
  }
}
