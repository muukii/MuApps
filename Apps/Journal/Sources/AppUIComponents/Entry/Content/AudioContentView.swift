import MuColor
import SwiftUI

/// Ambient-audio values needed by content rendering and export.
public struct AudioContentSource: Hashable, Sendable {
  public let fileURL: URL?

  public init(fileURL: URL? = nil) {
    self.fileURL = fileURL
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

    fileprivate var samples: [AudioWaveformSample] {
      switch preset {
      case .composer:
        return AudioWaveformSample.composerSamples
      case .overview, .detail:
        return AudioWaveformSample.savedSamples
      case .share:
        return AudioWaveformSample.shareSamples
      }
    }

    var barWidth: CGFloat { preset == .share ? 16 : 4 }
    var barSpacing: CGFloat { preset == .share ? 10 : 4 }
    var waveformOpacity: Double { preset == .share ? 0.44 : 0.62 }
    var minimumHeight: CGFloat? { preset == .detail ? 120 : nil }
  }

  let audio: AudioContentSource
  let style: Style

  @ViewBuilder
  var body: some View {
    switch style.preset {
    case .composer:
      waveform
        .frame(maxWidth: .infinity, minHeight: 68, alignment: .center)
    case .overview, .detail:
      VStack(alignment: .leading, spacing: 14) {
        Label("Audio", systemImage: "waveform")
          .font(.headline.weight(.semibold))

        waveform
          .frame(
            maxWidth: .infinity,
            minHeight: 52,
            alignment: .center
          )
      }
    case .share:
      VStack(alignment: .leading, spacing: 36) {
        Image(systemName: "waveform")
          .font(.system(size: 96, weight: .semibold))

        waveform
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
  }

  private var waveform: some View {
    HStack(alignment: .center, spacing: style.barSpacing) {
      ForEach(style.samples) { sample in
        Capsule()
          .fill(
            .appOnSecondaryContainer.opacity(
              audio.fileURL == nil && style.preset == .share
                ? style.waveformOpacity / 2
                : style.waveformOpacity
            )
          )
          .frame(width: style.barWidth, height: sample.height)
      }
    }
  }
}

private struct AudioWaveformSample: Identifiable {
  let id: Int
  let height: CGFloat

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

  static let shareSamples: [AudioWaveformSample] = [
    61, 109, 80, 143, 101, 127, 72, 135, 93, 116,
  ].enumerated().map { index, height in
    AudioWaveformSample(id: index, height: CGFloat(height))
  }
}

#Preview("Audio Content") {
  EntryContentPreviewCanvas {
    AudioContentView(
      audio: AudioContentSource(),
      style: .init(.detail)
    )
  }
}
