import AVFoundation
import SwiftUI

/// A self-contained ambient-sound capture surface: a record/stop control, a live
/// elapsed timer, and an input-level meter. Emits the finished recording through
/// `onFinish`.
public struct AudioCaptureView: View {

  @State private var recorder = AmbientAudioRecorder()
  @State private var permissionDenied = false
  @State private var errorMessage: String?

  private let onFinish: @MainActor @Sendable (AudioRecording) -> Void

  public init(onFinish: @escaping @MainActor @Sendable (AudioRecording) -> Void) {
    self.onFinish = onFinish
  }

  public var body: some View {
    VStack(spacing: 40) {
      Spacer()

      Text(Self.formatted(recorder.duration))
        .font(.system(size: 56, weight: .light, design: .rounded))
        .monospacedDigit()
        .contentTransition(.numericText())

      LevelMeter(level: recorder.level, isActive: recorder.state == .recording)
        .frame(height: 48)
        .padding(.horizontal, 40)

      Spacer()

      recordButton
        .padding(.bottom, 40)

      if let errorMessage {
        Text(errorMessage)
          .font(.footnote)
          .foregroundStyle(.red)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .alert("Microphone Access Needed", isPresented: $permissionDenied) {
      Button("OK", role: .cancel) {}
    } message: {
      Text("Enable microphone access in Settings to record ambient sound.")
    }
  }

  private var recordButton: some View {
    Button {
      toggleRecording()
    } label: {
      ZStack {
        Circle()
          .strokeBorder(.secondary, lineWidth: 4)
          .frame(width: 84, height: 84)
        RoundedRectangle(cornerRadius: recorder.state == .recording ? 6 : 32)
          .fill(.red)
          .frame(
            width: recorder.state == .recording ? 34 : 64,
            height: recorder.state == .recording ? 34 : 64
          )
      }
    }
    .buttonStyle(.plain)
    .animation(.smooth, value: recorder.state)
    .accessibilityLabel(recorder.state == .recording ? "Stop recording" : "Start recording")
  }

  private func toggleRecording() {
    switch recorder.state {
    case .recording:
      if let recording = recorder.stop() {
        onFinish(recording)
      }
    case .idle, .finished:
      Task { await beginRecording() }
    }
  }

  private func beginRecording() async {
    guard await AmbientAudioRecorder.requestPermission() else {
      permissionDenied = true
      return
    }
    do {
      errorMessage = nil
      try recorder.start()
    } catch {
      errorMessage = "Couldn't start recording: \(error.localizedDescription)"
    }
  }

  private static func formatted(_ duration: TimeInterval) -> String {
    let total = Int(duration)
    return String(format: "%02d:%02d", total / 60, total % 60)
  }
}

// MARK: - Level Meter

private struct LevelMeter: View {
  let level: Float
  let isActive: Bool

  private let barCount = 24

  var body: some View {
    GeometryReader { proxy in
      HStack(spacing: 4) {
        ForEach(0..<barCount, id: \.self) { index in
          let threshold = Float(index) / Float(barCount)
          RoundedRectangle(cornerRadius: 2)
            .fill(isActive && level >= threshold ? Color.accentColor : Color.secondary.opacity(0.2))
            .frame(height: barHeight(for: index, in: proxy.size.height))
            .frame(maxHeight: .infinity, alignment: .center)
        }
      }
      .animation(.linear(duration: 0.05), value: level)
    }
  }

  private func barHeight(for index: Int, in maxHeight: CGFloat) -> CGFloat {
    // Symmetric falloff from the center for a classic equalizer silhouette.
    let normalized = 1 - abs(CGFloat(index) - CGFloat(barCount) / 2) / (CGFloat(barCount) / 2)
    return maxHeight * (0.3 + 0.7 * normalized)
  }
}

#Preview {
  NavigationStack {
    AudioCaptureView { recording in
      print("finished:", recording.fileURL, recording.duration)
    }
    .navigationTitle("Ambient Sound")
  }
}
