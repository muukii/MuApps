import AVFoundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Configures AVFoundation playback objects for SwiftUI Observation.
///
/// Apple requires this global opt-in before creating `AVPlayer`,
/// `AVPlayerItem`, or related playback objects. Call this from
/// the app lifecycle before rendering video previews; `MutedLoopingVideoPlayer`
/// also calls it before creating its player so SwiftUI previews stay usable.
@MainActor
public enum VideoPlaybackObservationConfiguration {

  private static var isConfigured = false

  public static func configure() {
    guard isConfigured == false else { return }
    AVPlayer.isObservationEnabled = true
    VideoPlaybackAudioSessionPolicy.configureForMutedInlinePlayback()
    isConfigured = true
  }
}

/// A muted, looping video layer for compact card previews.
///
/// The SwiftUI view owns the playback objects in `@State` and observes their
/// AVFoundation state directly. The UIKit bridge only exposes an `AVPlayerLayer`
/// so playback lifecycle and scene visibility remain in the SwiftUI layer.
struct MutedLoopingVideoPlayer: View {

  let fileURL: URL
  let videoGravity: AVLayerVideoGravity
  let onReadyForPlayback: @MainActor () -> Void

  @Environment(\.scenePhase) private var scenePhase
  @State private var playback: MutedLoopingVideoPlayback?
  @State private var hasReportedReadyForPlayback = false
  @State private var isVisible = false

  init(
    fileURL: URL,
    videoGravity: AVLayerVideoGravity = .resizeAspectFill,
    onReadyForPlayback: @escaping @MainActor () -> Void = {}
  ) {
    self.fileURL = fileURL
    self.videoGravity = videoGravity
    self.onReadyForPlayback = onReadyForPlayback
  }

  var body: some View {
    Group {
      if let playback {
        MutedLoopingVideoPlayerLayer(
          player: playback.player,
          videoGravity: videoGravity
        )
        .onReceive(
          NotificationCenter.default.publisher(
            for: .AVPlayerItemDidPlayToEndTime,
            object: playback.item
          )
        ) { _ in
          playback.player.seek(to: .zero)
          playIfActive()
        }
      } else {
        Color.clear
      }
    }
    .task(id: fileURL) {
      configurePlayback()
    }
    .onAppear {
      isVisible = true
      playIfActive()
    }
    .onDisappear {
      isVisible = false
      pause()
    }
    .onChange(of: scenePhase) { _, newPhase in
      switch newPhase {
      case .active:
        playIfActive()
      case .background, .inactive:
        pause()
      @unknown default:
        pause()
      }
    }
    .onChange(of: playback?.item.status, initial: true) { _, status in
      guard status == .readyToPlay else { return }
      reportReadyForPlayback()
      playIfActive()
    }
    .onChange(of: playback?.player.timeControlStatus, initial: true) {
      _,
      status in
      guard status == .playing else { return }
      reportReadyForPlayback()
    }
  }

  private func configurePlayback() {
    VideoPlaybackObservationConfiguration.configure()
    pause()

    let item = AVPlayerItem(url: fileURL)
    let player = AVPlayer(playerItem: item)
    player.actionAtItemEnd = .none
    player.isMuted = true
    player.volume = 0

    hasReportedReadyForPlayback = false
    playback = MutedLoopingVideoPlayback(
      player: player,
      item: item
    )
    playIfActive()
  }

  private func playIfActive() {
    guard isVisible,
      scenePhase == .active,
      let playback
    else {
      return
    }

    playback.player.play()
  }

  private func pause() {
    playback?.player.pause()
  }

  private func reportReadyForPlayback() {
    guard hasReportedReadyForPlayback == false else { return }
    hasReportedReadyForPlayback = true
    onReadyForPlayback()
  }
}

/// Playback objects retained together for one looping preview.
private struct MutedLoopingVideoPlayback {
  let player: AVPlayer
  let item: AVPlayerItem
}

/// A minimal UIKit bridge that displays an existing player in an `AVPlayerLayer`.
#if canImport(UIKit)
private struct MutedLoopingVideoPlayerLayer: UIViewRepresentable {

  let player: AVPlayer
  let videoGravity: AVLayerVideoGravity

  func makeUIView(context: Context) -> MutedLoopingVideoPlayerLayerView {
    MutedLoopingVideoPlayerLayerView()
  }

  func updateUIView(
    _ uiView: MutedLoopingVideoPlayerLayerView,
    context: Context
  ) {
    uiView.configure(
      player: player,
      videoGravity: videoGravity
    )
  }

  static func dismantleUIView(
    _ uiView: MutedLoopingVideoPlayerLayerView,
    coordinator: ()
  ) {
    uiView.removePlayer()
  }
}
#elseif canImport(AppKit)
/// Native AppKit host for the shared `AVPlayerLayer` playback state.
private struct MutedLoopingVideoPlayerLayer: NSViewRepresentable {
  let player: AVPlayer
  let videoGravity: AVLayerVideoGravity

  func makeNSView(context: Context) -> MutedLoopingVideoPlayerLayerView {
    MutedLoopingVideoPlayerLayerView()
  }

  func updateNSView(
    _ nsView: MutedLoopingVideoPlayerLayerView,
    context: Context
  ) {
    nsView.configure(player: player, videoGravity: videoGravity)
  }

  static func dismantleNSView(
    _ nsView: MutedLoopingVideoPlayerLayerView,
    coordinator: ()
  ) {
    nsView.removePlayer()
  }
}

@MainActor
private final class MutedLoopingVideoPlayerLayerView: NSView {
  private let playerLayer = AVPlayerLayer()

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.addSublayer(playerLayer)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layout() {
    super.layout()
    playerLayer.frame = bounds
  }

  func configure(player: AVPlayer, videoGravity: AVLayerVideoGravity) {
    playerLayer.videoGravity = videoGravity
    if playerLayer.player !== player {
      playerLayer.player = player
    }
  }

  func removePlayer() {
    playerLayer.player = nil
  }
}
#endif

#if canImport(UIKit)
@MainActor
private final class MutedLoopingVideoPlayerLayerView: UIView {

  override static var layerClass: AnyClass {
    AVPlayerLayer.self
  }

  private var playerLayer: AVPlayerLayer {
    layer as! AVPlayerLayer
  }

  func configure(
    player: AVPlayer,
    videoGravity: AVLayerVideoGravity
  ) {
    playerLayer.videoGravity = videoGravity

    guard playerLayer.player !== player else {
      return
    }

    playerLayer.player = player
  }

  func removePlayer() {
    playerLayer.player = nil
  }
}
#endif

#Preview("Muted Looping Video Player") {
  MutedLoopingVideoPlayer(
    fileURL: MutedLoopingVideoPlayerPreviewFixture.videoURL,
    onReadyForPlayback: {
      print("Video is ready for playback")
    }
  )
  .aspectRatio(16 / 9, contentMode: .fit)
  .frame(width: 360)
  .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
  .padding(32)
  .background(.black.opacity(0.08))
}

private enum MutedLoopingVideoPlayerPreviewFixture {
  static let videoURL = URL(
    string:
      "https://cdn.dribbble.com/userupload/15163863/file/original-41db2055cf6cbadc9c86b0b288744134.mp4"
  )!
}
