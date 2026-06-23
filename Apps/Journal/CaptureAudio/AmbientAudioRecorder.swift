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
  /// Normalized input amplitude (0...1), derived from average power, for meters.
  public private(set) var level: Float = 0

  private var recorder: AVAudioRecorder?
  private var fileURL: URL?
  private var pollTask: Task<Void, Never>?

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
    self.level = 0
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
    self.level = 0
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
        self.level = Self.normalizedLevel(fromDecibels: power)
        self.duration = recorder.currentTime
        try? await Task.sleep(for: .milliseconds(50))
      }
    }
  }

  private func stopPolling() {
    pollTask?.cancel()
    pollTask = nil
  }

  /// Maps average power in decibels (−160...0) to a linear amplitude (0...1).
  private static func normalizedLevel(fromDecibels decibels: Float) -> Float {
    guard decibels.isFinite else { return 0 }
    let amplitude = pow(10, decibels / 20)
    return min(max(amplitude, 0), 1)
  }

  // No `deinit` cleanup needed: the poll loop captures `self` weakly and exits
  // on the next tick once the recorder is deallocated.
}
