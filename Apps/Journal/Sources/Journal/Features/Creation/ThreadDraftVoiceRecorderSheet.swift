import AVFoundation
import CaptureAudio
import SwiftUI

/// Native sheet shell for recording a voice/audio card from the composer.
///
/// The sheet does not create a draft until `AudioCaptureView` returns a completed
/// recording. That keeps cancellation side-effect free for the Creation surface.
struct ThreadDraftVoiceRecorderSheet: View {

  @Environment(\.dismiss) private var dismiss

  /// Existing draft to update. `nil` means the caller will decide where the
  /// recording should be inserted after capture completes.
  let card: ThreadDraftCard?

  /// Called with the completed recording before the sheet dismisses.
  let onFinish: @MainActor @Sendable (AudioRecording) -> Void

  var body: some View {
    NavigationStack {
      ThreadDraftAudioRecorderContent(card: card) { recording in
        onFinish(recording)
        dismiss()
      }
      .navigationTitle("Voice Record")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") {
            dismiss()
          }
        }
      }
    }
  }
}

/// Recorder content shared by the Creation sheet and the full-screen draft
/// editor. It shows playback controls when the draft already has audio, and the
/// live recorder otherwise.
struct ThreadDraftAudioRecorderContent: View {

  /// Existing draft whose recording can be played or replaced.
  let card: ThreadDraftCard?

  /// Called whenever the recorder completes a new take.
  let onFinish: @MainActor @Sendable (AudioRecording) -> Void

  @State private var isRecordingReplacement: Bool = false

  var body: some View {
    if let audio = card?.audio, isRecordingReplacement == false {
      ThreadDraftAudioExistingContent(
        fileURL: audio.fileURL,
        duration: audio.duration,
        onRecordAgain: {
          isRecordingReplacement = true
        }
      )
    } else {
      AudioCaptureView { recording in
        onFinish(recording)
        isRecordingReplacement = false
      }
    }
  }
}

/// Displays the recording already attached to an audio draft.
private struct ThreadDraftAudioExistingContent: View {

  let fileURL: URL
  let duration: TimeInterval?
  let onRecordAgain: @MainActor @Sendable () -> Void

  @State private var player: AVAudioPlayer?
  @State private var playbackError: String?

  var body: some View {
    VStack(spacing: 28) {
      Spacer()

      Image(systemName: "waveform")
        .font(.system(size: 72, weight: .light))
        .foregroundStyle(.tint)

      VStack(spacing: 8) {
        Text("Recorded Audio")
          .font(.title2.weight(.semibold))

        Text(duration.map(Self.formatted) ?? "--:--")
          .font(.system(size: 44, weight: .light, design: .rounded))
          .monospacedDigit()
      }

      if let playbackError {
        Text(playbackError)
          .font(.footnote)
          .foregroundStyle(.red)
          .multilineTextAlignment(.center)
          .padding(.horizontal, 32)
      }

      Spacer()

      HStack(spacing: 12) {
        Button {
          play()
        } label: {
          Label("Play", systemImage: "play.fill")
        }
        .buttonStyle(.borderedProminent)

        Button(action: onRecordAgain) {
          Label("Record Again", systemImage: "record.circle")
        }
        .buttonStyle(.bordered)
      }
      .padding(.bottom, 40)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onDisappear {
      player?.stop()
      player = nil
    }
  }

  private func play() {
    do {
      try AVAudioSession.sharedInstance().setCategory(.playback)
      try AVAudioSession.sharedInstance().setActive(true)
      let player = try AVAudioPlayer(contentsOf: fileURL)
      player.play()
      self.player = player
      playbackError = nil
    } catch {
      playbackError = "Couldn't play recording: \(error.localizedDescription)"
    }
  }

  private static func formatted(_ duration: TimeInterval) -> String {
    let total = Int(duration)
    return String(format: "%02d:%02d", total / 60, total % 60)
  }
}
