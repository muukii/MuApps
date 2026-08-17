import MuColor
import SwiftUI

/// Ambient-audio values needed by content rendering and export.
public struct AudioContentSource: Hashable, Sendable {
  public let fileURL: URL?
  /// Quantized `0...255` meter levels ordered across the full recording.
  public let waveformLevels: Data?

  public init(
    fileURL: URL? = nil,
    waveformLevels: Data? = nil
  ) {
    self.fileURL = fileURL
    self.waveformLevels = waveformLevels
  }
}

/// Renders ambient-audio content as a placement-specific waveform.
struct AudioContentView: View {

  /// Visual treatment owned by ambient-audio content.
  struct Style {
    let preset: EntryContentStyle

    init(_ preset: EntryContentStyle) {
      self.preset = preset
    }

    fileprivate var fallbackSamples: [AudioWaveformSample] {
      switch preset {
      case .composer:
        return AudioWaveformSample.composerSamples
      case .cell:
        return AudioWaveformSample.savedSamples
      }
    }

    fileprivate var waveformHeightRange: ClosedRange<CGFloat> { 12...70 }

    var barWidth: CGFloat { 4 }
    var barSpacing: CGFloat { 4 }
    var waveformOpacity: Double { 0.62 }
    var minimumHeight: CGFloat? {
      switch preset {
      case .composer:
        return nil
      case .cell:
        return 120
      }
    }
  }

  let audio: AudioContentSource
  let style: Style
  private let samples: [AudioWaveformSample]

  init(audio: AudioContentSource, style: Style) {
    self.audio = audio
    self.style = style
    self.samples = AudioWaveformSample.samples(
      from: audio.waveformLevels,
      maximumCount: style.fallbackSamples.count,
      heightRange: style.waveformHeightRange,
      fallback: style.fallbackSamples
    )
  }

  @ViewBuilder
  var body: some View {
    ZStack {
      switch style.preset {
      case .composer:
        waveform
          .frame(maxWidth: .infinity, minHeight: 68, alignment: .center)
      case .cell:
        VStack(alignment: .leading, spacing: 14) {
          waveform
            .frame(
              maxWidth: .infinity,
              minHeight: 52,
              alignment: .center
            )
        }
      }
    }
    .background(.appSecondaryContainer)
  }

  private var waveform: some View {
    HStack(alignment: .center, spacing: style.barSpacing) {
      ForEach(samples) { sample in
        Capsule()
          .fill(
            .appOnSecondaryContainer.opacity(style.waveformOpacity)
          )
          .frame(width: style.barWidth, height: sample.height)
      }
    }
  }
}

/// One fixed-position bar in a presentation-sized waveform summary.
struct AudioWaveformSample: Identifiable, Equatable {
  let id: Int
  let height: CGFloat

  /// Converts a full recording history into the number of bars a placement can
  /// display. Peak-per-bucket retains brief audible events when long recordings
  /// are compressed into a Cell-sized waveform.
  static func samples(
    from levels: Data?,
    maximumCount: Int,
    heightRange: ClosedRange<CGFloat>,
    fallback: [AudioWaveformSample]
  ) -> [AudioWaveformSample] {
    guard let levels else { return fallback }
    let summarizedLevels = downsampledLevels(
      levels,
      maximumCount: maximumCount
    )
    guard summarizedLevels.isEmpty == false else { return fallback }

    let heightDistance = heightRange.upperBound - heightRange.lowerBound
    return summarizedLevels.enumerated().map { index, level in
      let normalizedLevel = CGFloat(level) / CGFloat(UInt8.max)
      return AudioWaveformSample(
        id: index,
        height: heightRange.lowerBound + heightDistance * normalizedLevel
      )
    }
  }

  /// Returns at most `maximumCount` peak levels while preserving time order.
  static func downsampledLevels(
    _ levels: Data,
    maximumCount: Int
  ) -> [UInt8] {
    guard levels.isEmpty == false, maximumCount > 0 else { return [] }

    let source = [UInt8](levels)
    let outputCount = min(source.count, maximumCount)
    return (0..<outputCount).map { outputIndex in
      let startIndex = outputIndex * source.count / outputCount
      let endIndex = (outputIndex + 1) * source.count / outputCount
      return source[startIndex..<endIndex].max() ?? 0
    }
  }

  static let composerSamples: [AudioWaveformSample] = [
    18, 30, 24, 42, 34, 58, 46, 70, 38, 54, 28, 44,
  ].enumerated().map { index, height in
    AudioWaveformSample(id: index, height: CGFloat(height))
  }

  static let savedSamples: [AudioWaveformSample] = [
    18, 30, 24, 42, 34, 58, 46, 70, 38, 54, 28, 44, 64, 50, 36, 22,
  ].enumerated().map { index, height in
    AudioWaveformSample(id: index, height: CGFloat(height))
  }

}

#Preview("Audio Content") {
  EntryContentPreviewCanvas {
    AudioContentView(
      audio: AudioContentSource(),
      style: .init(.cell)
    )
  }
}
