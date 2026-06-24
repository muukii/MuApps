import AVFoundation
import SwiftUI

/// Standalone demo harness for `AudioCaptureView`. Captures a recording and lets
/// you play it back, so the component can be exercised on its own.
public struct AudioCaptureDemoView: View {

  @State private var lastRecording: AudioRecording?
  @State private var player: AVAudioPlayer?

  public init() {}

  public var body: some View {
    VStack(spacing: 0) {
      AudioCaptureView { recording in
        lastRecording = recording
      }

      if let lastRecording {
        Divider()
        HStack {
          VStack(alignment: .leading, spacing: 2) {
            Text("Last recording")
              .font(.caption)
              .foregroundStyle(.secondary)
            Text(String(format: "%.1fs", lastRecording.duration))
              .font(.callout.monospacedDigit())
          }
          Spacer()
          Button("Play", systemImage: "play.fill") {
            play(lastRecording)
          }
          .buttonStyle(.borderedProminent)
        }
        .padding()
      }
    }
    .background(.background)
    .navigationTitle("Ambient Sound")
    .navigationBarTitleDisplayMode(.inline)
  }

  private func play(_ recording: AudioRecording) {
    do {
      try AVAudioSession.sharedInstance().setCategory(.playback)
      try AVAudioSession.sharedInstance().setActive(true)
      let player = try AVAudioPlayer(contentsOf: recording.fileURL)
      player.play()
      self.player = player
    } catch {
      print("playback failed:", error)
    }
  }
}

#Preview {
  NavigationStack {
    AudioCaptureDemoView()
  }
}
