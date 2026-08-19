import CoreGraphics
import Foundation
import Testing

@testable import AppUIComponents

struct AudioWaveformSampleTests {

  @Test
  func downsampledLevels_averageEachTimeBucket() {
    let levels = Data([0, 64, 255, 32, 128, 16])

    let result = AudioWaveformSample.downsampledLevels(
      levels,
      maximumCount: 3
    )

    #expect(result == [32, 144, 72])
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
  func downsampledLevels_spanWholeRecordingRegardlessOfLength() {
    // A long recording keeps its head and tail: the last slice must still be
    // the quiet ending, not a bar dropped off the end.
    let levels = Data(Array(repeating: 200, count: 600) + Array(repeating: 0, count: 600))

    let result = AudioWaveformSample.downsampledLevels(
      levels,
      maximumCount: 12
    )

    #expect(result.count == 12)
    #expect(result.prefix(6).allSatisfy { $0 == 200 })
    #expect(result.suffix(6).allSatisfy { $0 == 0 })
  }

  @Test
  func downsampledLevels_keepContourInsteadOfSaturatingOnLongRecording() {
    // One loud transient inside an otherwise quiet stretch must not drag the
    // whole slice to full height the way a peak-per-slice summary would.
    var quietWithOneSpike = Array(repeating: UInt8(20), count: 100)
    quietWithOneSpike[50] = 255

    let result = AudioWaveformSample.downsampledLevels(
      Data(quietWithOneSpike),
      maximumCount: 2
    )

    #expect(result.allSatisfy { $0 < 50 })
  }

  @Test
  func samples_normalizeHeightsAgainstRecordingPeak() {
    // A uniformly quiet recording still uses the full height range, so its
    // shape stays legible instead of collapsing onto the baseline.
    let levels = Data([10, 20, 30, 40])

    let samples = AudioWaveformSample.samples(
      from: levels,
      maximumCount: 4,
      heightRange: 4...40,
      fallback: [255]
    )

    #expect(samples.map(\.height) == [13, 22, 31, 40])
  }

  @Test
  func samples_keepSilentRecordingAtMinimumHeight() {
    let samples = AudioWaveformSample.samples(
      from: Data([0, 0, 0]),
      maximumCount: 3,
      heightRange: 4...40,
      fallback: [255]
    )

    #expect(samples.map(\.height) == [4, 4, 4])
  }

  @Test
  func samples_tileFallbackAcrossAvailableBarsWhenWaveformIsUnavailable() {
    let fallback: [UInt8] = [0, 255]

    let missing = AudioWaveformSample.samples(
      from: nil,
      maximumCount: 5,
      heightRange: 12...70,
      fallback: fallback
    )
    let empty = AudioWaveformSample.samples(
      from: Data(),
      maximumCount: 5,
      heightRange: 12...70,
      fallback: fallback
    )

    #expect(missing.map(\.height) == [12, 70, 12, 70, 12])
    #expect(empty.map(\.height) == [12, 70, 12, 70, 12])
  }

  @Test
  func samples_shrinkFallbackToFitSmallContainer() {
    let heightRange: ClosedRange<CGFloat> = 4...8

    let samples = AudioWaveformSample.samples(
      from: nil,
      maximumCount: 20,
      heightRange: heightRange,
      fallback: AudioWaveformSample.savedLevels
    )

    #expect(samples.count == 20)
    #expect(samples.allSatisfy { heightRange.contains($0.height) })
  }

  @Test
  func samples_drawNothingBeforeAWidthIsKnown() {
    let samples = AudioWaveformSample.samples(
      from: Data([10, 20, 30]),
      maximumCount: 0,
      heightRange: 4...40,
      fallback: AudioWaveformSample.savedLevels
    )

    #expect(samples.isEmpty)
  }
}

struct AudioContentStyleTests {

  @Test
  func barCount_fillsAvailableWidthWithoutOverflowing() {
    let style = AudioContentView.Style(.cell)
    let width: CGFloat = 100

    let count = style.barCount(fittingWidth: width)

    let occupiedWidth =
      CGFloat(count) * style.barWidth + CGFloat(count - 1) * style.barSpacing
    #expect(occupiedWidth <= width)
    #expect(occupiedWidth + style.barSpacing + style.barWidth > width)
  }

  @Test
  func barCount_isZeroBeforeLayoutReportsAWidth() {
    let style = AudioContentView.Style(.cell)

    #expect(style.barCount(fittingWidth: 0) == 0)
  }
}
