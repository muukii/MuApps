import MuColor
import SwiftUI

/// Ambient-audio values needed by content rendering and export.
public struct AudioContentSource: Hashable, Sendable {
  public let fileURL: URL?
  /// Quantized `0...255` meter levels ordered across the full recording.
  public let waveformLevels: Data?
  /// Recorded length in seconds, measured when the audio was captured.
  ///
  /// Imported audio and recordings produced by older builds may not carry a
  /// measured length, so rendering must treat this value as optional.
  public let duration: TimeInterval?

  public init(
    fileURL: URL? = nil,
    waveformLevels: Data? = nil,
    duration: TimeInterval? = nil
  ) {
    self.fileURL = fileURL
    self.waveformLevels = waveformLevels
    self.duration = duration
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

    fileprivate var fallbackLevels: [UInt8] {
      switch preset {
      case .composer:
        return AudioWaveformSample.composerLevels
      case .cell:
        return AudioWaveformSample.savedLevels
      }
    }

    var barWidth: CGFloat { 3 }
    var barSpacing: CGFloat { 3 }
    var waveformOpacity: Double { 0.62 }

    /// Bars that fit `width` at this style's bar geometry, where `n` bars
    /// occupy `n * barWidth + (n - 1) * barSpacing`. The waveform's resolution
    /// belongs to the space it is drawn in, not to the placeholder's length.
    func barCount(fittingWidth width: CGFloat) -> Int {
      let slot = barWidth + barSpacing
      guard width > 0, slot > 0 else { return 0 }
      return max(1, Int((width + barSpacing) / slot))
    }
  }

  let audio: AudioContentSource
  let style: Style

  private var player: AudioContentPlayer { .shared }

  /// Whether this card's own recording is the one currently playing.
  private var isPlaying: Bool {
    guard let fileURL = audio.fileURL else {
      return false
    }

    return player.isPlaying(fileURL)
  }

  private var playbackButton: some View {
    Button {
      guard let fileURL = audio.fileURL else {
        return
      }

      player.toggle(fileURL: fileURL)
    } label: {
      Circle()
        .foregroundStyle(.quinary)
        .frame(width: 36, height: 36)
        .overlay {
          Image(systemName: isPlaying ? "pause.fill" : "play.fill")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .foregroundStyle(.tint)
            .frame(width: 14)
            // The play triangle reads as off-center inside its own bounding
            // box; the pause bars are already symmetric.
            .padding(.leading, isPlaying ? 0 : 4)
            .contentTransition(.symbolEffect(.replace))
        }
    }
    // The card itself carries a tap target and a swipe gesture, so the control
    // stays visually flat and claims only the circle.
    .buttonStyle(.plain)
    .disabled(audio.fileURL == nil)
    .animation(.snappy(duration: 0.2), value: isPlaying)
    .accessibilityLabel(
      isPlaying
        ? Text(
          "Pause Recording",
          bundle: #bundle,
          comment: "Button that stops the recording playing on this card."
        )
        : Text(
          "Play Recording",
          bundle: #bundle,
          comment: "Button that plays the recording attached to this card."
        )
    )
  }

  @ViewBuilder
  var body: some View {
    HStack(spacing: 16) {

      playbackButton

      waveform
        .frame(height: 30)
        .frame(maxWidth: .infinity)

      if let duration = audio.duration {
        DurationLabel(duration: duration)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 12)
  }

  private var waveform: some View {
    GeometryReader { proxy in
      HStack(alignment: .center, spacing: style.barSpacing) {
        ForEach(samples(for: proxy.size)) { sample in
          Capsule()
            .fill(
              .appOnSecondaryContainer.opacity(style.waveformOpacity)
            )
            .frame(width: style.barWidth, height: sample.height)
        }
      }
      .frame(
        width: proxy.size.width,
        height: proxy.size.height,
        alignment: .leading
      )
    }
  }

  private func samples(for containerSize: CGSize) -> [AudioWaveformSample] {
    let minimumBarHeight: CGFloat = 4
    return AudioWaveformSample.samples(
      from: audio.waveformLevels,
      maximumCount: style.barCount(fittingWidth: containerSize.width),
      heightRange: minimumBarHeight...max(containerSize.height, minimumBarHeight),
      fallback: style.fallbackLevels
    )
  }
}

/// Shows how long the attached recording runs.
private struct DurationLabel: View {

  let duration: TimeInterval

  var body: some View {
    Text(Self.formatted(duration))
      .font(.caption)
      .fontWeight(.medium)
      .monospacedDigit()
      .fixedSize()
      .foregroundStyle(.tint)
  }

  private static func formatted(_ duration: TimeInterval) -> String {
    let total = Int(max(0, duration.rounded()))
    guard total >= 3600 else {
      return String(format: "%02d:%02d", total / 60, total % 60)
    }

    return String(
      format: "%d:%02d:%02d",
      total / 3600,
      (total % 3600) / 60,
      total % 60
    )
  }

}

#Preview {
  DurationLabel(duration: 100)
}

/// One fixed-position bar in a presentation-sized waveform summary.
struct AudioWaveformSample: Identifiable, Equatable {
  let id: Int
  let height: CGFloat

  /// Summarizes a whole recording into the bars a placement can display.
  ///
  /// Every bar covers an equal slice of the recording, so the result always
  /// spans it end to end. Heights are normalized against the summary's own
  /// peak, which keeps the shape legible at any duration — it expresses
  /// relative dynamics within one recording, not absolute loudness between
  /// recordings.
  ///
  /// `fallback` is expressed on the same normalized `0...255` scale as recorded
  /// levels and is tiled to `maximumCount`, so a missing waveform fills the same
  /// width and resolves its heights through `heightRange` too.
  static func samples(
    from levels: Data?,
    maximumCount: Int,
    heightRange: ClosedRange<CGFloat>,
    fallback: [UInt8]
  ) -> [AudioWaveformSample] {
    guard maximumCount > 0 else { return [] }

    let summarizedLevels =
      levels.map { downsampledLevels($0, maximumCount: maximumCount) } ?? []
    let resolvedLevels =
      summarizedLevels.isEmpty
      ? tiledLevels(fallback, count: maximumCount)
      : summarizedLevels

    let peakLevel = resolvedLevels.max() ?? 0
    let heightDistance = heightRange.upperBound - heightRange.lowerBound
    return resolvedLevels.enumerated().map { index, level in
      let normalizedLevel =
        peakLevel == 0 ? 0 : CGFloat(level) / CGFloat(peakLevel)
      return AudioWaveformSample(
        id: index,
        height: heightRange.lowerBound + heightDistance * normalizedLevel
      )
    }
  }

  /// Returns at most `maximumCount` levels, each the mean of one equal slice of
  /// the recording, preserving time order.
  ///
  /// The mean, not the peak: stored levels are already 0.05s average-power
  /// readings on a perceptual dB scale, so peak-of-averages pins every bar to
  /// the recording's loudest moment once the compression ratio grows, and a long
  /// recording collapses into a flat wall. Averaging keeps the loudness contour,
  /// and degrades to the identity when a slice holds a single level.
  ///
  /// A recording shorter than `maximumCount` keeps its own resolution rather
  /// than inventing bars.
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
      let slice = source[startIndex..<endIndex]
      guard slice.isEmpty == false else { return 0 }

      let total = slice.reduce(0) { $0 + Int($1) }
      return UInt8((total + slice.count / 2) / slice.count)
    }
  }

  /// Repeats `levels` up to `count` so a placeholder spans the available width.
  static func tiledLevels(_ levels: [UInt8], count: Int) -> [UInt8] {
    guard levels.isEmpty == false, count > 0 else { return [] }
    return (0..<count).map { levels[$0 % levels.count] }
  }

  /// Placeholder shape used until a recording carries its own levels. Kept on
  /// the normalized `0...255` scale — the original `18...70pt` design divided by
  /// its own peak — and tiled to whatever bar count the container affords.
  static let composerLevels: [UInt8] = [
    66, 109, 87, 153, 124, 211, 168, 255, 138, 197, 102, 160,
  ]

  static let savedLevels: [UInt8] = composerLevels + [233, 182, 131, 80]

}

#Preview("Audio Content") {
  EntryContentPreviewCanvas {
    AudioContentView(
      audio: AudioContentSource(duration: 83),
      style: .init(.cell)
    )
  }
}

#Preview("Audio Content - No Duration") {
  EntryContentPreviewCanvas {
    AudioContentView(
      audio: AudioContentSource(),
      style: .init(.cell)
    )
  }
}
