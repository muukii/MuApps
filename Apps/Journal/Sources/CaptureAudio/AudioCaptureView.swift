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

      WaveformMeter(samples: recorder.samples, isActive: recorder.state == .recording)
        .frame(height: 64)
        .padding(.horizontal, 32)

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

// MARK: - Waveform Meter

/// A live, scrolling waveform in the style of the iMessage voice message UI:
/// each bar is a real amplitude sample, mirrored around a center line, with the
/// newest sample entering at the right. The bars occupy fixed positional slots,
/// so as the underlying samples shift left each slot springs to its neighbour's
/// value — reading as flowing horizontal motion.
private struct WaveformMeter: View {
  let samples: [Float]
  let isActive: Bool

  private let barSpacing: CGFloat = 3
  private let minBarHeight: CGFloat = 4

  var body: some View {
    GeometryReader { proxy in
      let count = max(samples.count, 1)
      let barWidth = max(
        (proxy.size.width - barSpacing * CGFloat(count - 1)) / CGFloat(count),
        1
      )
      HStack(spacing: barSpacing) {
        // Fixed positional slots, not identity-bearing data: index-as-id is the
        // intended model — slot N always renders the Nth sample in the window.
        ForEach(samples.indices, id: \.self) { index in
          Capsule()
            .fill(.tint)
            .frame(width: barWidth, height: height(for: samples[index], in: proxy.size.height))
            .frame(maxHeight: .infinity, alignment: .center)
        }
      }
      .frame(width: proxy.size.width, height: proxy.size.height)
      .opacity(isActive ? 1 : 0.3)
      .animation(.spring(response: 0.18, dampingFraction: 0.72), value: samples)
      .animation(.smooth, value: isActive)
    }
  }

  private func height(for sample: Float, in maxHeight: CGFloat) -> CGFloat {
    let amplitude = CGFloat(min(max(sample, 0), 1))
    return minBarHeight + (maxHeight - minBarHeight) * amplitude
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
