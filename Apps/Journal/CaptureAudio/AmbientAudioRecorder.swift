import AVFoundation
import Observation

// MARK: - Value

/// A finished ambient-sound recording. The file lives in the temporary
/// directory; the host is responsible for moving/persisting it if it wants to
/// keep it.
public struct AudioRecording: Sendable, Equatable {
  public var fileURL: URL
  public var duration: TimeInterval

  public init(fileURL: URL, duration: TimeInterval) {
    self.fileURL = fileURL
    self.duration = duration
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

  /// Number of amplitude samples kept in `samples`. At `pollInterval` cadence
  /// this is the width of the waveform's time window (~2.4s).
  public static let sampleCount = 48

  private var recorder: AVAudioRecorder?
  private var fileURL: URL?
  private var pollTask: Task<Void, Never>?

  private static let pollInterval: Duration = .milliseconds(50)

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

  public func start() throws {
    guard state != .recording else { return }

    let session = AVAudioSession.sharedInstance()
    try session.setCategory(.record, mode: .default)
    try session.setActive(true)

    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("ambient-\(UUID().uuidString)")
      .appendingPathExtension("m4a")

    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVSampleRateKey: 44_100,
      AVNumberOfChannelsKey: 1,
      AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
    ]

    let recorder = try AVAudioRecorder(url: url, settings: settings)
    recorder.isMeteringEnabled = true
    recorder.record()

    self.recorder = recorder
    self.fileURL = url
    self.duration = 0
    self.samples = Array(repeating: 0, count: Self.sampleCount)
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
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

    self.recorder = nil
    self.fileURL = nil
    self.samples = Array(repeating: 0, count: Self.sampleCount)
    self.duration = finalDuration
    self.state = .finished

    return AudioRecording(fileURL: fileURL, duration: finalDuration)
  }

  private func startPolling() {
    pollTask?.cancel()
    pollTask = Task { [weak self] in
      while Task.isCancelled == false {
        guard let self, let recorder = self.recorder else { return }
        recorder.updateMeters()
        let power = recorder.averagePower(forChannel: 0)
        var next = self.samples
        next.removeFirst()
        next.append(Self.normalizedLevel(fromDecibels: power))
        self.samples = next
        self.duration = recorder.currentTime
        try? await Task.sleep(for: Self.pollInterval)
      }
    }
  }

  private func stopPolling() {
    pollTask?.cancel()
    pollTask = nil
  }

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
