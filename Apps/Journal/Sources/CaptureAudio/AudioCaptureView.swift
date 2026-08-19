import AVFoundation
import SwiftUI

#if os(iOS)
  import Combine
#endif

/// A self-contained ambient-sound capture surface: a record/stop control, a live
/// elapsed timer, and an input-level meter. Emits the finished recording through
/// `onFinish`.
public struct AudioCaptureView: View {

  @State private var recorder = AmbientAudioRecorder()
  @State private var permissionDenied = false
  @State private var errorMessage: String?
  @State private var inputRefreshTask: Task<Void, Never>?
  @State private var isChangingRecordingState = false

  private let onFinish: @MainActor @Sendable (AudioRecording) -> Void

  public init(onFinish: @escaping @MainActor @Sendable (AudioRecording) -> Void) {
    self.onFinish = onFinish
  }

  public var body: some View {
    VStack(spacing: 40) {
      Spacer()

      AudioRecordingDurationLabel(recorder: recorder)

      AudioRecordingWaveformMeter(recorder: recorder)
        .frame(height: 64)
        .padding(.horizontal, 32)

      #if os(iOS)
        AudioInputSelector(
          inputs: recorder.availableInputs,
          selection: recorder.inputSelection,
          resolvedInputName: recorder.resolvedInput?.name
            ?? String(localized: "Automatic"),
          isEnabled: recorder.state != .recording
            && isChangingRecordingState == false
            && recorder.availableInputs.isEmpty == false,
          onSelect: { recorder.selectInput($0) }
        )
        .padding(.horizontal, 32)

        if recorder.availableChannelModes.count > 1 {
          AudioChannelModePicker(
            modes: recorder.availableChannelModes,
            selection: recorder.channelMode,
            isEnabled: recorder.state != .recording
              && isChangingRecordingState == false,
            onSelect: { recorder.selectChannelMode($0) }
          )
          .padding(.horizontal, 32)
        }
      #endif

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
    #if os(iOS)
      .task {
        await refreshAudioInputs(reportingErrors: false)
      }
      .onReceive(
        NotificationCenter.default.publisher(
          for: AVAudioSession.availableInputsChangeNotification
        )
      ) { _ in
        scheduleAudioInputRefresh(reportingErrors: recorder.state == .recording)
      }
      .onReceive(
        NotificationCenter.default.publisher(
          for: AVAudioSession.routeChangeNotification
        )
      ) { _ in
        scheduleAudioInputRefresh(reportingErrors: recorder.state == .recording)
      }
      .onReceive(
        NotificationCenter.default.publisher(
          for: AVAudioSession.interruptionNotification
        )
      ) { notification in
        finishRecordingOnInterruption(notification)
      }
      .onDisappear {
        inputRefreshTask?.cancel()
      }
    #endif
  }

  private var recordButton: some View {
    Button {
      guard isChangingRecordingState == false else { return }
      isChangingRecordingState = true
      Task {
        defer { isChangingRecordingState = false }
        await toggleRecording()
      }
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
    .disabled(isChangingRecordingState)
    .animation(.smooth, value: recorder.state)
    .accessibilityLabel(
      recorder.state == .recording ? "Stop recording" : "Start recording"
    )
  }

  private func toggleRecording() async {
    switch recorder.state {
    case .recording:
      if let recording = await recorder.stop() {
        onFinish(recording)
      }
    case .idle, .finished:
      await beginRecording()
    }
  }

  private func beginRecording() async {
    guard await AmbientAudioRecorder.requestPermission() else {
      permissionDenied = true
      return
    }
    do {
      errorMessage = nil
      try await recorder.start()
    } catch {
      errorMessage = "Couldn't start recording: \(error.localizedDescription)"
    }
  }

  #if os(iOS)
    /// Ends the take when the system interrupts recording (phone call, Siri).
    /// The partial recording is delivered instead of leaving the surface stuck
    /// in a recording state whose audio I/O already stopped.
    private func finishRecordingOnInterruption(_ notification: Notification) {
      guard
        let rawType =
          notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
        AVAudioSession.InterruptionType(rawValue: rawType) == .began,
        recorder.state == .recording,
        isChangingRecordingState == false
      else { return }

      isChangingRecordingState = true
      Task {
        defer { isChangingRecordingState = false }
        if let recording = await recorder.stop() {
          onFinish(recording)
        }
      }
    }

    private func scheduleAudioInputRefresh(reportingErrors: Bool) {
      inputRefreshTask?.cancel()
      inputRefreshTask = Task {
        try? await Task.sleep(for: .milliseconds(50))
        guard Task.isCancelled == false else { return }
        await refreshAudioInputs(reportingErrors: reportingErrors)
      }
    }

    private func refreshAudioInputs(reportingErrors: Bool) async {
      do {
        try await recorder.refreshAudioInputs()
      } catch is CancellationError {
        return
      } catch {
        if reportingErrors {
          errorMessage = error.localizedDescription
        }
        // An inactive session may not expose inputs until permission or hardware
        // is ready. `start()` repeats configuration and reports actionable errors.
      }
    }
  #endif
}

/// Isolates the high-frequency duration observation from the capture surface.
private struct AudioRecordingDurationLabel: View {
  let recorder: AmbientAudioRecorder

  var body: some View {
    Text(Self.formatted(recorder.duration))
      .font(.system(size: 56, weight: .light, design: .rounded))
      .monospacedDigit()
      .contentTransition(.numericText())
  }

  private static func formatted(_ duration: TimeInterval) -> String {
    let total = Int(duration)
    return String(format: "%02d:%02d", total / 60, total % 60)
  }
}

#if os(iOS)
  /// Stateless microphone selector. The recorder owns route state; this view only
  /// renders narrow values and sends the user's next transient selection upward.
  private struct AudioInputSelector: View {
    let inputs: [AudioRecordingInput]
    let selection: AudioRecordingInputSelection
    let resolvedInputName: String
    let isEnabled: Bool
    let onSelect: @MainActor @Sendable (AudioRecordingInputSelection) -> Void

    var body: some View {
      Menu {
        Picker(
          "Microphone",
          selection: Binding(
            get: { selection },
            set: { onSelect($0) }
          )
        ) {
          Text("Automatic")
            .tag(AudioRecordingInputSelection.automatic)

          ForEach(inputs) { input in
            Text(verbatim: input.name)
              .tag(AudioRecordingInputSelection.input(id: input.id))
          }
        }
      } label: {
        HStack(spacing: 12) {
          Image(systemName: "mic")
            .imageScale(.large)

          VStack(alignment: .leading, spacing: 2) {
            Text("Microphone")
              .font(.caption)
              .foregroundStyle(.secondary)
            Text(verbatim: resolvedInputName)
              .font(.body)
              .foregroundStyle(.primary)
              .lineLimit(1)
          }

          Spacer(minLength: 8)

          Image(systemName: "chevron.up.chevron.down")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
        }
        .contentShape(.rect)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
      }
      .buttonStyle(.plain)
      .disabled(isEnabled == false)
      .accessibilityLabel("Microphone")
      .accessibilityValue(Text(verbatim: resolvedInputName))
    }
  }
#endif

#if os(iOS)
  /// Stateless channel-layout selector shown only when the resolved microphone
  /// can record stereo. The recorder owns the effective mode; this view renders
  /// narrow values and sends the user's next transient choice upward.
  private struct AudioChannelModePicker: View {
    let modes: [AudioRecordingChannelMode]
    let selection: AudioRecordingChannelMode
    let isEnabled: Bool
    let onSelect: @MainActor @Sendable (AudioRecordingChannelMode) -> Void

    var body: some View {
      Picker(
        "Channels",
        selection: Binding(
          get: { selection },
          set: { onSelect($0) }
        )
      ) {
        ForEach(modes, id: \.self) { mode in
          Text(mode.displayName)
            .tag(mode)
        }
      }
      .pickerStyle(.segmented)
      .disabled(isEnabled == false)
      .accessibilityLabel("Channels")
      .accessibilityValue(Text(selection.displayName))
    }
  }
#endif

// MARK: - Waveform Meter

/// Isolates the recorder's high-frequency meter observation from unrelated controls.
private struct AudioRecordingWaveformMeter: View {
  let recorder: AmbientAudioRecorder

  var body: some View {
    let liveMeter = recorder.liveMeter
    WaveformMeter(
      samples: liveMeter.renderingSamples,
      visibleBarCount: liveMeter.samples.count,
      newestSampleDate: liveMeter.newestSampleDate,
      sampleInterval: AmbientAudioRecorder.sampleInterval,
      isActive: recorder.state == .recording
    )
  }
}

/// A time-based scrolling waveform whose bars are drawn in one Canvas pass.
///
/// Recorder measurements remain at 20 Hz. The animation timeline interpolates
/// their horizontal position at the display cadence, so each measured bar moves
/// exactly one slot before the next value enters from the trailing edge.
private struct WaveformMeter: View {
  let samples: [Float]
  let visibleBarCount: Int
  let newestSampleDate: Date?
  let sampleInterval: TimeInterval
  let isActive: Bool

  private let barSpacing: CGFloat = 3
  private let minBarHeight: CGFloat = 4

  var body: some View {
    TimelineView(.animation(paused: isActive == false)) { timeline in
      Canvas { context, size in
        let phase = LiveWaveformCanvasLayout.scrollPhase(
          at: timeline.date,
          newestSampleDate: newestSampleDate,
          sampleInterval: sampleInterval
        )
        let layout = LiveWaveformCanvasLayout(
          size: size,
          visibleBarCount: visibleBarCount,
          phase: phase,
          barSpacing: barSpacing,
          minimumBarHeight: minBarHeight
        )
        var bars = Path()
        for (index, sample) in samples.enumerated() {
          let rect = layout.barRect(for: sample, at: index)
          let cornerRadius = min(rect.width, rect.height) / 2
          bars.addRoundedRect(
            in: rect,
            cornerSize: CGSize(width: cornerRadius, height: cornerRadius)
          )
        }

        context.clip(to: Path(CGRect(origin: .zero, size: size)))
        context.fill(bars, with: .style(.tint))
      }
    }
    .opacity(isActive ? 1 : 0.3)
    .animation(.smooth, value: isActive)
  }
}

// MARK: - Formatting Helpers

extension AudioRecordingChannelMode {
  fileprivate var displayName: String {
    switch self {
    case .mono:
      return String(localized: "Mono")
    case .stereoFront:
      return String(localized: "Stereo · Front")
    case .stereoBack:
      return String(localized: "Stereo · Back")
    }
  }
}

#Preview {
  AudioCaptureView { recording in
    print("finished:", recording.fileURL, recording.duration)
  }
  .frame(height: 400)
  .frame(maxHeight: .infinity)
}
