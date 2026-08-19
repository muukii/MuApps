import AVFoundation
import Observation

#if os(iOS)
  import UIKit
#endif

// MARK: - Value

/// A finished ambient-sound recording. The file lives in the temporary
/// directory; the host is responsible for moving/persisting it if it wants to
/// keep it.
public struct AudioRecording: Sendable, Equatable, Codable {
  public var fileURL: URL
  public var duration: TimeInterval
  /// Meter history measured while the audio file was recorded.
  ///
  /// Imported audio and recordings produced by older builds may not have a
  /// waveform, so persistence and rendering must treat this value as optional.
  public var waveform: AudioWaveform?

  public init(
    fileURL: URL,
    duration: TimeInterval,
    waveform: AudioWaveform? = nil
  ) {
    self.fileURL = fileURL
    self.duration = duration
    self.waveform = waveform
  }
}

/// One atomic live-meter update consumed by the recording waveform renderer.
///
/// `samples` is the 48-slot visible window after the newest measurement was
/// appended. `leadingSample` retains the value that just left that window so a
/// time-based renderer can move it offscreen while the newest value enters from
/// the right without discontinuity at a polling boundary.
struct LiveAudioMeterSnapshot: Sendable, Equatable {
  /// The fixed-width rolling window after the latest meter update.
  var samples: [Float]
  /// The sample removed from the leading edge by the latest update.
  var leadingSample: Float
  /// The wall-clock instant associated with the newest sample.
  var newestSampleDate: Date?

  /// The outgoing value, visible window, and incoming value needed for one
  /// continuous one-slot transition.
  var renderingSamples: [Float] {
    [leadingSample] + samples
  }

  /// Creates a silent fixed-width window before recording measurements arrive.
  static func resting(sampleCount: Int) -> Self {
    precondition(sampleCount > 0)
    return Self(
      samples: Array(repeating: 0, count: sampleCount),
      leadingSample: 0,
      newestSampleDate: nil
    )
  }

  func appending(_ sample: Float, at date: Date) -> Self {
    var nextSamples = samples
    let nextLeadingSample = nextSamples.removeFirst()
    nextSamples.append(sample)
    return Self(
      samples: nextSamples,
      leadingSample: nextLeadingSample,
      newestSampleDate: date
    )
  }
}

// MARK: - Recorder

/// Records the whole ambient soundscape to an AAC (.m4a) file via
/// `AVAudioRecorder`, exposing live duration and a normalized input level for
/// UI feedback. Self-contained: no persistence, no shared app state.
@MainActor
@Observable
public final class AmbientAudioRecorder {

  public enum State: Equatable {
    case idle
    case recording
    case finished
  }

  public private(set) var state: State = .idle
  public private(set) var duration: TimeInterval = 0
  /// A rolling window of recent normalized amplitudes (0...1), oldest first,
  /// newest last. Each entry is a real measurement sampled at `sampleInterval`;
  /// rendering it as bars produces a live, scrolling waveform. Fixed length —
  /// padded with zeros before any audio arrives so the meter has a resting shape.
  public var samples: [Float] { liveMeter.samples }

  /// Atomic live-meter state used by the CaptureAudio rendering layer.
  private(set) var liveMeter = LiveAudioMeterSnapshot.resting(sampleCount: sampleCount)

  #if os(iOS)
    /// Microphones currently reported by the configured iOS audio session.
    private(set) var availableInputs: [AudioRecordingInput] = []

    /// Transient user choice for this recorder presentation.
    private(set) var inputSelection: AudioRecordingInputSelection = .automatic

    /// Input that Automatic or the explicit choice currently resolves to.
    private(set) var resolvedInput: AudioRecordingInput?

    /// Transient channel-layout choice for this recorder presentation.
    private(set) var channelMode: AudioRecordingChannelMode = .mono

    /// Channel modes the currently resolved microphone can record.
    var availableChannelModes: [AudioRecordingChannelMode] {
      resolvedInput?.supportedChannelModes ?? [.mono]
    }
  #endif

  /// Number of amplitude samples kept in `samples`. At `sampleInterval` cadence
  /// this is the width of the waveform's time window (~2.4s).
  public static let sampleCount = 48

  /// Nominal cadence shared by live scrolling and persisted waveform metadata.
  static let sampleInterval: TimeInterval = 0.05

  private var recorder: AVAudioRecorder?
  private let recordingController = AudioRecordingSessionController()
  private var fileURL: URL?
  private var pollTask: Task<Void, Never>?
  /// Complete quantized history for the active recording.
  private var recordedLevels = Data()

  public init() {}

  /// Requests microphone authorization. The host must call this (and get `true`)
  /// before `start()`.
  public static func requestPermission() async -> Bool {
    await withCheckedContinuation { continuation in
      AVAudioApplication.requestRecordPermission { granted in
        continuation.resume(returning: granted)
      }
    }
  }

  public static var permission: AVAudioApplication.recordPermission {
    AVAudioApplication.shared.recordPermission
  }

  #if os(iOS)
    /// Refreshes the microphones available to the iOS recording category.
    ///
    /// Calling this method doesn't activate recording or interrupt another app's
    /// audio. If a route changes during a recording, the current selection is
    /// reapplied to the active session.
    func refreshAudioInputs() async throws {
      let snapshot = try await recordingController.refresh(
        selection: inputSelection,
        applyingPreferredInput: state == .recording
      )
      try Task.checkCancellation()
      applyAudioSessionSnapshot(snapshot)
    }

    /// Stores a transient input choice. The live port is resolved again when
    /// recording starts so a stale device reference is never retained.
    func selectInput(_ selection: AudioRecordingInputSelection) {
      switch selection {
      case .automatic:
        inputSelection = .automatic
      case .input(let id) where availableInputs.contains(where: { $0.id == id }):
        inputSelection = selection
      case .input:
        inputSelection = .automatic
      }

      resolvedInput = AudioRecordingInputSelectionPolicy.resolvedInput(
        for: inputSelection,
        availableInputs: availableInputs,
        currentInputID: resolvedInput?.id
      )
      channelMode = AudioRecordingChannelModePolicy.effectiveMode(
        for: channelMode,
        supportedModes: availableChannelModes
      )
    }

    /// Stores a transient channel-mode choice, clamped to what the resolved
    /// microphone supports.
    func selectChannelMode(_ mode: AudioRecordingChannelMode) {
      channelMode = AudioRecordingChannelModePolicy.effectiveMode(
        for: mode,
        supportedModes: availableChannelModes
      )
    }
  #endif

  public func start() async throws {
    guard state != .recording else { return }

    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("ambient-\(UUID().uuidString)")
      .appendingPathExtension("m4a")

    let startResult: AudioRecordingStartResult
    #if os(iOS)
      startResult = try await recordingController.startRecording(
        fileURL: url,
        selection: inputSelection,
        channelMode: AudioRecordingChannelModePolicy.effectiveMode(
          for: channelMode,
          supportedModes: availableChannelModes
        ),
        inputOrientation: Self.currentStereoInputOrientation()
      )
      applyAudioSessionSnapshot(startResult.sessionSnapshot)
      channelMode = startResult.channelMode
    #else
      startResult = try await recordingController.startRecording(fileURL: url)
    #endif

    self.recorder = startResult.recorder
    self.fileURL = url
    self.duration = 0
    self.liveMeter = .resting(sampleCount: Self.sampleCount)
    self.recordedLevels.removeAll(keepingCapacity: true)
    self.state = .recording
    startPolling()
  }

  /// Stops recording and returns the resulting file. Returns `nil` if not
  /// currently recording.
  @discardableResult
  public func stop() async -> AudioRecording? {
    guard let recorder, let fileURL else { return nil }

    stopPolling()
    let finalDuration = await recordingController.stopRecording(recorder)

    let waveform =
      recordedLevels.isEmpty
      ? nil
      : AudioWaveform(
        sampleInterval: Self.sampleInterval,
        levels: recordedLevels
      )

    self.recorder = nil
    self.fileURL = nil
    self.liveMeter = .resting(sampleCount: Self.sampleCount)
    self.recordedLevels.removeAll(keepingCapacity: true)
    self.duration = finalDuration
    self.state = .finished

    return AudioRecording(
      fileURL: fileURL,
      duration: finalDuration,
      waveform: waveform
    )
  }

  private func startPolling() {
    pollTask?.cancel()
    pollTask = Task { [weak self] in
      while Task.isCancelled == false {
        guard let self, let recorder = self.recorder else { return }
        guard let reading = await self.recordingController.meter(recorder) else { return }
        guard Task.isCancelled == false else { return }
        let normalizedLevel = Self.normalizedLevel(fromDecibels: reading.averagePower)
        self.liveMeter = self.liveMeter.appending(normalizedLevel, at: .now)
        self.recordedLevels.append(AudioWaveform.quantizedLevel(normalizedLevel))
        self.duration = reading.duration
        try? await Task.sleep(for: .seconds(Self.sampleInterval))
      }
    }
  }

  private func stopPolling() {
    pollTask?.cancel()
    pollTask = nil
  }

  #if os(iOS)
    /// Publishes a copied session snapshot after the serial controller finishes.
    private func applyAudioSessionSnapshot(
      _ snapshot: AudioRecordingSessionSnapshot
    ) {
      availableInputs = snapshot.availableInputs
      inputSelection = snapshot.selection
      resolvedInput = snapshot.resolvedInput
      channelMode = AudioRecordingChannelModePolicy.effectiveMode(
        for: channelMode,
        supportedModes: availableChannelModes
      )
    }

    /// Stereo bakes left/right into the file, so the input orientation must
    /// match how the user is holding the interface when the take starts; the
    /// system forbids changing it mid-recording.
    private static func currentStereoInputOrientation() -> AVAudioSession.StereoOrientation {
      let scenes = UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
      let scene =
        scenes.first { $0.activationState == .foregroundActive } ?? scenes.first

      guard let interfaceOrientation = scene?.effectiveGeometry.interfaceOrientation
      else {
        return .portrait
      }

      switch interfaceOrientation {
      case .portrait, .unknown:
        return .portrait
      case .portraitUpsideDown:
        return .portraitUpsideDown
      case .landscapeLeft:
        return .landscapeLeft
      case .landscapeRight:
        return .landscapeRight
      @unknown default:
        return .portrait
      }
    }
  #endif

  /// Decibel level treated as silence. Average power runs −160...0 dB, but the
  /// usable range for voice/ambient sound sits near the top; flooring here keeps
  /// the meter responsive instead of pinned to the bottom of the raw scale.
  private static let silenceFloor: Float = -50

  /// Maps average power in decibels to a perceptual 0...1, linear in dB above
  /// `silenceFloor`. Linear-in-dB tracks loudness as the ear hears it, so the
  /// waveform reacts to normal speech rather than only to loud peaks.
  private static func normalizedLevel(fromDecibels decibels: Float) -> Float {
    guard decibels.isFinite else { return 0 }
    let clamped = max(decibels, silenceFloor)
    return (clamped - silenceFloor) / -silenceFloor
  }

  // No `deinit` cleanup needed: the poll loop captures `self` weakly and exits
  // on the next tick once the recorder is deallocated.
}
