import AVFoundation
import Observation

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
  /// newest last. Each entry is a real measurement sampled at `pollInterval`;
  /// rendering it as bars produces a live, scrolling waveform. Fixed length —
  /// padded with zeros before any audio arrives so the meter has a resting shape.
  public private(set) var samples: [Float] = Array(repeating: 0, count: sampleCount)

  #if os(iOS)
    /// Microphones currently reported by the configured iOS audio session.
    private(set) var availableInputs: [AudioRecordingInput] = []

    /// Transient user choice for this recorder presentation.
    private(set) var inputSelection: AudioRecordingInputSelection = .automatic

    /// Input that Automatic or the explicit choice currently resolves to.
    private(set) var resolvedInput: AudioRecordingInput?
  #endif

  /// Number of amplitude samples kept in `samples`. At `pollInterval` cadence
  /// this is the width of the waveform's time window (~2.4s).
  public static let sampleCount = 48

  private var recorder: AVAudioRecorder?
  private var fileURL: URL?
  private var pollTask: Task<Void, Never>?
  /// Complete quantized history for the active recording.
  private var recordedLevels = Data()

  private static let pollInterval: Duration = .milliseconds(50)
  private static let waveformSampleInterval: TimeInterval = 0.05

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
    func refreshAudioInputs() throws {
      let session = AVAudioSession.sharedInstance()
      try Self.configureAudioSession(session)
      try reloadAudioInputs(
        from: session,
        applyingPreferredInput: state == .recording
      )
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
        currentInputID: AVAudioSession.sharedInstance().currentRoute.inputs.first?.uid
      )
    }
  #endif

  public func start() throws {
    guard state != .recording else { return }

    #if os(iOS)
      let session = AVAudioSession.sharedInstance()
      do {
        try Self.configureAudioSession(session)
        try session.setActive(true)
        try reloadAudioInputs(from: session, applyingPreferredInput: true)
      } catch {
        Self.deactivateAudioSession(session)
        throw error
      }
    #endif

    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("ambient-\(UUID().uuidString)")
      .appendingPathExtension("m4a")

    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVSampleRateKey: 44_100,
      AVNumberOfChannelsKey: 1,
      AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
    ]

    let recorder: AVAudioRecorder
    do {
      recorder = try AVAudioRecorder(url: url, settings: settings)
    } catch {
      #if os(iOS)
        Self.deactivateAudioSession(session)
      #endif
      throw error
    }
    recorder.isMeteringEnabled = true
    recorder.record()

    self.recorder = recorder
    self.fileURL = url
    self.duration = 0
    self.samples = Array(repeating: 0, count: Self.sampleCount)
    self.recordedLevels.removeAll(keepingCapacity: true)
    self.state = .recording
    startPolling()
  }

  /// Stops recording and returns the resulting file. Returns `nil` if not
  /// currently recording.
  @discardableResult
  public func stop() -> AudioRecording? {
    guard let recorder, let fileURL else { return nil }

    let finalDuration = recorder.currentTime
    recorder.stop()
    stopPolling()
    #if os(iOS)
      Self.deactivateAudioSession(AVAudioSession.sharedInstance())
    #endif

    let waveform =
      recordedLevels.isEmpty
      ? nil
      : AudioWaveform(
        sampleInterval: Self.waveformSampleInterval,
        levels: recordedLevels
      )

    self.recorder = nil
    self.fileURL = nil
    self.samples = Array(repeating: 0, count: Self.sampleCount)
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
        recorder.updateMeters()
        let power = recorder.averagePower(forChannel: 0)
        let normalizedLevel = Self.normalizedLevel(fromDecibels: power)
        var next = self.samples
        next.removeFirst()
        next.append(normalizedLevel)
        self.samples = next
        self.recordedLevels.append(AudioWaveform.quantizedLevel(normalizedLevel))
        self.duration = recorder.currentTime
        try? await Task.sleep(for: Self.pollInterval)
      }
    }
  }

  private func stopPolling() {
    pollTask?.cancel()
    pollTask = nil
  }

  #if os(iOS)
    /// Configures an input-only category while making Bluetooth HFP microphones
    /// available. No output route, including the built-in speaker, is selected.
    private static func configureAudioSession(_ session: AVAudioSession) throws {
      try session.setCategory(
        .record,
        mode: .default,
        options: [.allowBluetoothHFP]
      )
    }

    /// Rebuilds value inputs and optionally applies the resolved live port.
    private func reloadAudioInputs(
      from session: AVAudioSession,
      applyingPreferredInput: Bool
    ) throws {
      let ports = session.availableInputs ?? []
      let inputs = ports.map(AudioRecordingInput.init(port:))
      availableInputs = inputs

      if case .input(let id) = inputSelection,
        inputs.contains(where: { $0.id == id }) == false
      {
        inputSelection = .automatic
      }

      let requestedInput = AudioRecordingInputSelectionPolicy.resolvedInput(
        for: inputSelection,
        availableInputs: inputs,
        currentInputID: session.currentRoute.inputs.first?.uid
      )

      guard applyingPreferredInput else {
        resolvedInput = requestedInput
        return
      }

      let preferredPort = ports.first { $0.uid == requestedInput?.id }
      if session.preferredInput?.uid != preferredPort?.uid {
        try session.setPreferredInput(preferredPort)
      }
      resolvedInput =
        session.currentRoute.inputs.first.map(AudioRecordingInput.init(port:))
        ?? requestedInput
    }

    /// Releases Tinycurve's shared-session preference before notifying other apps
    /// that recording no longer owns the audio session.
    private static func deactivateAudioSession(_ session: AVAudioSession) {
      try? session.setPreferredInput(nil)
      try? session.setActive(false, options: .notifyOthersOnDeactivation)
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
