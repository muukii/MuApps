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

  let model: VideoPreviewModel

  var body: some View {
    ZStack(alignment: .bottom) {
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
        GeometryReader { proxy in
          let playerBounds = CGSize(
            width: proxy.size.width,
            height: max(
              0,
              proxy.size.height
                - Self.controlsHeight
                - Self.controlsSpacing
                - Self.controlsBottomPadding
            )
          )
          let fittedSize = Self.fittedPlayerSize(
            aspectRatio: playerPresentationAspectRatio,
            inside: playerBounds
          )

          VStack(spacing: Self.controlsSpacing) {
            ZStack {
              PlayerLayerSurface(player: model.player)
                .frame(width: fittedSize.width, height: fittedSize.height)
                .clipShape(.rect(cornerRadius: 8))
                .accessibilityHidden(true)
            }
            .frame(height: playerBounds.height)

            EditorPlaybackControls(model: model)
              .frame(height: Self.controlsHeight)
              .padding(.horizontal, 16)
              .padding(.bottom, Self.controlsBottomPadding)
          }
        }
      }
    }
  }

  private static let controlsHeight: CGFloat = 44
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

  /// Fits an aspect ratio inside the space reserved above the controls.
  ///
  /// An explicit size keeps tall surfaces from overflowing the flexible
  /// `GeometryReader` allocation into the transport controls.
  private static func fittedPlayerSize(
    aspectRatio: CGFloat,
    inside bounds: CGSize
  ) -> CGSize {
    guard
      aspectRatio.isFinite,
      aspectRatio > 0,
      bounds.width.isFinite,
      bounds.height.isFinite,
      bounds.width > 0,
      bounds.height > 0
    else {
      return .zero
    }

    if bounds.width / bounds.height > aspectRatio {
      return CGSize(width: bounds.height * aspectRatio, height: bounds.height)
    } else {
      return CGSize(width: bounds.width, height: bounds.width / aspectRatio)
    }
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
    .foregroundStyle(.secondary)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .environment(\.colorScheme, .dark)
  }
}

/// Presents play/pause and timeline seeking for an editor preview.
private struct EditorPlaybackControls: View {

  let model: VideoPreviewModel

  @State private var scrubberProgress = 0.0
  @State private var isScrubbing = false

  var body: some View {
    HStack(spacing: 2) {
      
      Button(action: model.togglePlayback) {
        Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
          .font(.body.weight(.semibold))
          .frame(width: 44, height: 44)
          .contentTransition(.symbolEffect(.replace))
      }
      .sensoryFeedback(trigger: model.isPlaying, { oldValue, newValue in
        return .impact
      })
      .buttonStyle(.plain)
      .accessibilityLabel(model.isPlaying ? "Pause" : "Play")
      .accessibilityIdentifier("video-playback-toggle")

      HStack(spacing: 12) {
        Text(Self.format(time: displayedTime))
          .frame(minWidth: 36, alignment: .trailing)
          .foregroundStyle(.secondary)

        Slider(
          value: $scrubberProgress,
          in: 0...1,
          onEditingChanged: setScrubbing
        ) {
          Text("Video position")
        }
        .tint(.primary)
        .disabled(model.playbackDuration <= 0)
        .accessibilityValue(
          "\(Self.format(time: displayedTime)) of \(Self.format(time: model.playbackDuration))"
        )
        .accessibilityIdentifier("video-playback-timeline")

        Text(Self.format(time: model.playbackDuration))
          .frame(minWidth: 36, alignment: .leading)
          .foregroundStyle(.secondary)
      }

    }
    .font(.caption.monospacedDigit())
    .foregroundStyle(.primary)
    .padding(.horizontal, 8)
    .padding(.vertical, 8)
    .background(
      Capsule()
        .foregroundStyle(.regularMaterial)
        // .foregroundStyle(.thinMaterial)
    )    
    .onAppear {
      scrubberProgress = model.playbackProgress
    }
    .onChange(of: model.playbackProgress) { _, progress in
      guard isScrubbing == false else { return }
      scrubberProgress = progress
    }
    .onChange(of: scrubberProgress) { _, progress in
      guard isScrubbing else { return }
      model.seek(toProgress: progress)
    }
  }

  private var displayedTime: TimeInterval {
    if isScrubbing {
      return model.playbackDuration * scrubberProgress
    } else {
      return model.playbackTime
    }
  }

  private func setScrubbing(_ isEditing: Bool) {
    if isEditing {
      isScrubbing = true
      model.beginSeeking()
    } else {
      model.seek(toProgress: scrubberProgress)
      model.endSeeking()
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
