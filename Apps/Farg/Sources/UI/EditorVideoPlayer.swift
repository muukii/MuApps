//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import AVFoundation
import Foundation
import SwiftUI
import UIKit

/// Displays the editor preview with transport controls owned entirely by Färg.
///
/// The underlying `AVPlayerLayer` renders only video. Playback buttons and the
/// timeline remain regular SwiftUI views so their layout and behavior can
/// evolve independently from AVKit's standard player interface.
struct EditorVideoPlayer: View {

  @Environment(\.displayScale) private var displayScale

  let model: VideoPreviewModel

  var body: some View {
    let currentDisplayScale = displayScale

    ZStack {
      VStack(spacing: Self.controlsSpacing) {
        PlayerLayerSurface(player: model.player)
          .aspectRatio(playerPresentationAspectRatio, contentMode: .fit)
          .clipShape(.rect(cornerRadius: 8))
          .accessibilityHidden(true)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .onGeometryChange(for: PreviewViewportMeasurement.self) { proxy in
            PreviewViewportMeasurement(
              sizeInPoints: proxy.size,
              displayScale: currentDisplayScale
            )
          } action: { measurement in
            model.updateViewport(
              sizeInPoints: measurement.sizeInPoints,
              displayScale: measurement.displayScale
            )
          }

        EditorPlaybackControls(model: model)
          .padding(.horizontal, 16)
          .padding(.bottom, Self.controlsBottomPadding)
      }
      .opacity(model.renderState == .ready ? 1 : 0)
      .allowsHitTesting(model.renderState == .ready)
      .accessibilityHidden(model.renderState != .ready)

      switch model.renderState {
      case .empty:
        Color.black
      case .preparing:
        EditorPreviewStatus(
          title: "Preparing preview…",
          symbol: nil,
          showsProgress: true
        )
      case .failed:
        EditorPreviewStatus(
          title: "Preview unavailable",
          symbol: "exclamationmark.triangle",
          showsProgress: false
        )
      case .ready:
        EmptyView()
      }
    }
  }

  /// A normalized SwiftUI layout measurement used to suppress duplicate
  /// viewport notifications.
  private nonisolated struct PreviewViewportMeasurement: Equatable, Sendable {
    let sizeInPoints: CGSize
    let displayScale: CGFloat
  }

  private static let controlsSpacing: CGFloat = 8
  private static let controlsBottomPadding: CGFloat = 12

  /// The visible item's display ratio after orientation and composition.
  ///
  /// `presentationSize` becomes valid when the item is ready and is tracked
  /// directly through AVFoundation's Swift Observation support. The render size
  /// avoids a transient fallback ratio while a new composition is installed.
  private var playerPresentationAspectRatio: CGFloat {
    guard let item = model.player.currentItem else {
      return 16 / 9
    }
    return Self.aspectRatio(for: item.presentationSize)
      ?? Self.aspectRatio(for: item.videoComposition?.renderSize ?? .zero)
      ?? 16 / 9
  }

  private static func aspectRatio(for size: CGSize) -> CGFloat? {
    guard
      size.width.isFinite,
      size.height.isFinite,
      size.width > 0,
      size.height > 0
    else {
      return nil
    }
    return size.width / size.height
  }
}

/// Replaces the video surface while its desired recipe is not renderable.
private struct EditorPreviewStatus: View {

  let title: LocalizedStringKey
  let symbol: String?
  let showsProgress: Bool

  var body: some View {
    VStack(spacing: 10) {
      if showsProgress {
        ProgressView()
          .tint(.primary)
      } else if let symbol {
        Image(systemName: symbol)
          .font(.title2)
      }

      Text(title)
        .font(.callout.weight(.medium))
    }
    .foregroundStyle(.primary.secondary)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

/// Adapts preview model state and actions into playback component values.
private struct EditorPlaybackControls: View {

  let model: VideoPreviewModel

  var body: some View {
    EditorPlaybackControlsComponent(
      isPlaying: model.isPlaying,
      isMuted: model.isMuted,
      playbackTime: model.playbackTime,
      playbackDuration: model.playbackDuration,
      playbackProgress: model.playbackProgress,
      onTogglePlayback: {
        model.togglePlayback()
      },
      onToggleMute: {
        model.toggleMute()
      },
      onBeginSeeking: {
        model.beginSeeking()
      },
      onSeek: { progress in
        model.seek(toProgress: progress)
      },
      onEndSeeking: {
        model.endSeeking()
      }
    )
  }
}

/// Renders preview transport controls from display values and user actions.
///
/// The component deliberately has no knowledge of `VideoPreviewModel`, which
/// keeps its layout, interaction states, and future previews inexpensive to
/// construct.
private struct EditorPlaybackControlsComponent: View {

  let isPlaying: Bool
  let isMuted: Bool
  let playbackTime: TimeInterval
  let playbackDuration: TimeInterval
  let playbackProgress: Double
  let onTogglePlayback: @MainActor @Sendable () -> Void
  let onToggleMute: @MainActor @Sendable () -> Void
  let onBeginSeeking: @MainActor @Sendable () -> Void
  let onSeek: @MainActor @Sendable (Double) -> Void
  let onEndSeeking: @MainActor @Sendable () -> Void

  @State private var scrubberProgress = 0.0
  @State private var isScrubbing = false

  var body: some View {
    HStack(spacing: 2) {

      Button(action: onTogglePlayback) {
        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
          .font(.body.weight(.semibold))
          .frame(width: 38, height: 38)
          .contentTransition(.symbolEffect(.replace))
      }
      .sensoryFeedback(.impact, trigger: isPlaying)
      .buttonStyle(.plain)
      .accessibilityLabel(isPlaying ? "Pause" : "Play")
      .accessibilityIdentifier("video-playback-toggle")
  
      HStack(spacing: 12) {
        Text(Self.format(time: displayedTime))
          .frame(minWidth: 28, alignment: .trailing)
          .foregroundStyle(.secondary)

        Slider(
          value: $scrubberProgress,
          in: 0...1,
          onEditingChanged: setScrubbing
        ) {
          Text("Video position")
        }
        .tint(.primary)
        .disabled(playbackDuration <= 0)
        .accessibilityValue(
          "\(Self.format(time: displayedTime)) of \(Self.format(time: playbackDuration))"
        )
        .accessibilityIdentifier("video-playback-timeline")

        Text(Self.format(time: playbackDuration))
          .frame(minWidth: 28, alignment: .leading)
          .foregroundStyle(.secondary)
      }
      
      Button(action: onToggleMute) {
        Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
          .font(.body.weight(.semibold))
          .frame(width: 38, height: 38)
          .contentTransition(.symbolEffect(.replace))
      }
      .sensoryFeedback(.selection, trigger: isMuted)
      .buttonStyle(.plain)
      .accessibilityLabel(isMuted ? "Unmute" : "Mute")
      .accessibilityIdentifier("video-mute-toggle")
    }
    .font(.caption.monospacedDigit())
    .foregroundStyle(.primary)
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(
      Capsule()
        .foregroundStyle(.foreground.quinary)
    )
    .onAppear {
      scrubberProgress = playbackProgress
    }
    .onChange(of: playbackProgress) { _, progress in
      guard isScrubbing == false else { return }
      scrubberProgress = progress
    }
    .onChange(of: scrubberProgress) { _, progress in
      guard isScrubbing else { return }
      onSeek(progress)
    }
  }

  private var displayedTime: TimeInterval {
    if isScrubbing {
      return playbackDuration * scrubberProgress
    } else {
      return playbackTime
    }
  }

  private func setScrubbing(_ isEditing: Bool) {
    if isEditing {
      isScrubbing = true
      onBeginSeeking()
    } else {
      onSeek(scrubberProgress)
      onEndSeeking()
      isScrubbing = false
    }
  }

  private static func format(time: TimeInterval) -> String {
    guard time.isFinite, time > 0 else { return "0:00" }
    let totalSeconds = Int(time.rounded(.down))
    let hours = totalSeconds / 3_600
    let minutes = (totalSeconds % 3_600) / 60
    let seconds = totalSeconds % 60

    if hours > 0 {
      return String(format: "%d:%02d:%02d", hours, minutes, seconds)
    } else {
      return String(format: "%d:%02d", minutes, seconds)
    }
  }
}

#Preview("Playback controls", traits: .sizeThatFitsLayout) {
  @Previewable @State var isPlaying = false
  @Previewable @State var isMuted = true
  @Previewable @State var playbackProgress = 0.35
  let playbackDuration: TimeInterval = 125

  EditorPlaybackControlsComponent(
    isPlaying: isPlaying,
    isMuted: isMuted,
    playbackTime: playbackDuration * playbackProgress,
    playbackDuration: playbackDuration,
    playbackProgress: playbackProgress,
    onTogglePlayback: {
      isPlaying.toggle()
    },
    onToggleMute: {
      isMuted.toggle()
    },
    onBeginSeeking: {},
    onSeek: { progress in
      playbackProgress = progress
    },
    onEndSeeking: {}
  )
  .padding(.horizontal, 16)
  .padding(.vertical, 24)
  .frame(width: 390)
  .background(.background.secondary)
}

/// Bridges an `AVPlayerLayer` into SwiftUI without adopting AVKit controls.
private struct PlayerLayerSurface: UIViewRepresentable {

  let player: AVPlayer

  func makeUIView(context: Context) -> PlayerLayerContainerView {
    let view = PlayerLayerContainerView()
    view.playerLayer.videoGravity = .resizeAspect
    view.playerLayer.player = player
    return view
  }

  func updateUIView(_ uiView: PlayerLayerContainerView, context: Context) {
    if uiView.playerLayer.player !== player {
      uiView.playerLayer.player = player
    }
  }
}

/// Hosts one aspect-fit player layer as the complete UIKit rendering surface.
private final class PlayerLayerContainerView: UIView {

  override class var layerClass: AnyClass {
    AVPlayerLayer.self
  }

  var playerLayer: AVPlayerLayer {
    layer as! AVPlayerLayer
  }
}
