import Foundation
import Observation
@preconcurrency import AVFoundation

@Observable
@MainActor
final class VoiceRecorderViewModel {
  private enum RecorderError: LocalizedError {
    case missingBuiltInMicrophone
    case missingRecording
    case recorderDidNotStart
    case playerDidNotStart

    var errorDescription: String? {
      switch self {
      case .missingBuiltInMicrophone:
        return "Device microphone is not available."
      case .missingRecording:
        return "Record a clip before playing it."
      case .recorderDidNotStart:
        return "Recording could not be started."
      case .playerDidNotStart:
        return "Playback could not be started."
      }
    }
  }

  private let session = AVAudioSession.sharedInstance()
  private var inputPorts: [AVAudioSessionPortDescription] = []
  private var recorder: AVAudioRecorder?
  private var player: AVAudioPlayer?
  private var monitorEngine: AVAudioEngine?
  private var delayNode: AVAudioUnitDelay?
  private var meteringTask: Task<Void, Never>?
  private var playbackTask: Task<Void, Never>?

  private(set) var inputDevices: [AudioInputDevice] = []
  var selectedInputID = ""

  private(set) var isPrepared = false
  private(set) var isPermissionDenied = false
  private(set) var isRecording = false
  private(set) var isPlaying = false
  private(set) var isMonitoring = false
  private(set) var audioLevel: Float = 0
  private(set) var recordingDuration: TimeInterval = 0
  private(set) var playbackProgress: Double = 0
  private(set) var lastRecordingDuration: TimeInterval = 0
  private(set) var outputRouteName = "System Output"
  private(set) var activeInputName = "No Input"
  private(set) var isHeadphoneOutput = false
  private(set) var errorMessage: String?

  var monitorDelay: Double = 0.65 {
    didSet {
      delayNode?.delayTime = monitorDelay
    }
  }

  var hasRecording: Bool {
    guard let lastRecordingURL else { return false }
    return FileManager.default.fileExists(atPath: lastRecordingURL.path)
  }

  var canSelectInput: Bool {
    !isRecording && !isMonitoring
  }

  var selectedInputName: String {
    inputDevices.first(where: { $0.id == selectedInputID })?.name ?? "Device Microphone"
  }

  var recordingDurationText: String {
    Self.durationText(recordingDuration)
  }

  var lastRecordingDurationText: String {
    Self.durationText(lastRecordingDuration)
  }

  private var lastRecordingURL: URL?

  func prepare() async {
    errorMessage = nil

    let granted = await AVAudioApplication.requestRecordPermission()
    guard granted else {
      isPermissionDenied = true
      isPrepared = false
      refreshRoute()
      return
    }

    isPermissionDenied = false

    do {
      try configureDiscoverySession()
      refreshAudioInputs()
      isPrepared = true
    } catch {
      setError(error)
    }
  }

  func refreshAudioInputs() {
    inputPorts = session.availableInputs ?? []
    inputDevices = inputPorts.map(AudioInputDevice.init(port:))

    if selectedInputID.isEmpty || inputDevices.contains(where: { $0.id == selectedInputID }) == false {
      selectedInputID = inputDevices.first(where: \.isBuiltIn)?.id ?? inputDevices.first?.id ?? ""
    }

    refreshRoute()
  }

  func selectInput(id: String) {
    selectedInputID = id

    guard canSelectInput else { return }

    do {
      try applyPreferredInput(id: id)
      refreshRoute()
    } catch {
      setError(error)
    }
  }

  func toggleRecording() async {
    if isRecording {
      stopRecording()
    } else {
      await startRecording()
    }
  }

  func togglePlayback() {
    if isPlaying {
      stopPlayback()
    } else {
      startPlayback()
    }
  }

  func toggleMonitoring() async {
    if isMonitoring {
      stopMonitoring()
    } else {
      await startMonitoring()
    }
  }

  func stopAll() {
    if isRecording {
      stopRecording()
    }

    stopPlayback(restoreDiscovery: false)
    stopMonitoring(restoreDiscovery: false)
  }

  private func startRecording() async {
    guard await ensurePermission() else { return }

    stopPlayback(restoreDiscovery: false)
    stopMonitoring(restoreDiscovery: false)
    errorMessage = nil

    do {
      try configureRecordingSession()

      let url = recordingURL
      removeFileIfNeeded(at: url)
      lastRecordingURL = nil
      lastRecordingDuration = 0
      playbackProgress = 0

      let settings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
        AVSampleRateKey: 44_100,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 96_000,
        AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
      ]

      let recorder = try AVAudioRecorder(url: url, settings: settings)
      recorder.isMeteringEnabled = true
      recorder.prepareToRecord()

      guard recorder.record() else {
        throw RecorderError.recorderDidNotStart
      }

      self.recorder = recorder
      isRecording = true
      recordingDuration = 0
      audioLevel = 0
      startMeteringTask()
      refreshRoute()
    } catch {
      setError(error)
    }
  }

  private func stopRecording() {
    guard let recorder else { return }

    meteringTask?.cancel()
    meteringTask = nil

    recorder.updateMeters()
    recordingDuration = recorder.currentTime
    lastRecordingDuration = recorder.currentTime
    recorder.stop()

    lastRecordingURL = recorder.url
    self.recorder = nil
    isRecording = false
    audioLevel = 0
    refreshRoute()
  }

  private func startPlayback() {
    guard let url = lastRecordingURL, FileManager.default.fileExists(atPath: url.path) else {
      setError(RecorderError.missingRecording)
      return
    }

    stopMonitoring(restoreDiscovery: false)
    stopPlayback(restoreDiscovery: false)
    errorMessage = nil

    do {
      try configurePlaybackSession()

      let player = try AVAudioPlayer(contentsOf: url)
      player.prepareToPlay()

      guard player.play() else {
        throw RecorderError.playerDidNotStart
      }

      self.player = player
      isPlaying = true
      playbackProgress = 0
      startPlaybackTask()
      refreshRoute()
    } catch {
      setError(error)
    }
  }

  private func stopPlayback(restoreDiscovery: Bool = true) {
    playbackTask?.cancel()
    playbackTask = nil

    player?.stop()
    player = nil
    isPlaying = false
    playbackProgress = 0

    if restoreDiscovery {
      restoreDiscoverySessionIfIdle()
    }
  }

  private func startMonitoring() async {
    guard await ensurePermission() else { return }

    stopPlayback(restoreDiscovery: false)
    stopMonitoring(restoreDiscovery: false)
    errorMessage = nil

    do {
      try configureMonitoringSession()

      let engine = AVAudioEngine()
      let delay = AVAudioUnitDelay()
      delay.delayTime = monitorDelay
      delay.feedback = 0
      delay.lowPassCutoff = 22_050
      delay.wetDryMix = 100

      engine.attach(delay)

      let inputNode = engine.inputNode
      let inputFormat = inputNode.outputFormat(forBus: 0)
      engine.connect(inputNode, to: delay, format: inputFormat)
      engine.connect(delay, to: engine.mainMixerNode, format: inputFormat)

      try engine.start()

      monitorEngine = engine
      delayNode = delay
      isMonitoring = true
      refreshRoute()
    } catch {
      setError(error)
    }
  }

  private func stopMonitoring(restoreDiscovery: Bool = true) {
    guard let monitorEngine else { return }

    monitorEngine.stop()
    monitorEngine.reset()
    self.monitorEngine = nil
    delayNode = nil
    isMonitoring = false

    if restoreDiscovery {
      restoreDiscoverySessionIfIdle()
    } else {
      refreshRoute()
    }
  }

  private func ensurePermission() async -> Bool {
    if isPrepared, isPermissionDenied == false {
      return true
    }

    await prepare()
    return isPrepared
  }

  private func configureDiscoverySession() throws {
    try session.setCategory(
      .playAndRecord,
      mode: .default,
      options: [.allowBluetooth, .allowBluetoothA2DP]
    )
    try session.setActive(true)
  }

  private func configureRecordingSession() throws {
    try session.setCategory(
      .playAndRecord,
      mode: .default,
      options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker]
    )
    try session.setActive(true)
    try applyPreferredInput(id: selectedInputID)
  }

  private func configurePlaybackSession() throws {
    try session.setCategory(.playback, mode: .default)
    try session.setActive(true)
  }

  private func configureMonitoringSession() throws {
    try session.setCategory(
      .playAndRecord,
      mode: .measurement,
      options: [.allowBluetoothA2DP]
    )
    try? session.setPreferredIOBufferDuration(0.005)
    try session.setActive(true)
    try applyBuiltInMicrophone()
  }

  private func applyPreferredInput(id: String) throws {
    guard let port = inputPorts.first(where: { $0.uid == id }) else { return }
    try session.setPreferredInput(port)
  }

  private func applyBuiltInMicrophone() throws {
    refreshAudioInputs()

    guard let builtIn = inputPorts.first(where: { $0.portType == .builtInMic }) else {
      throw RecorderError.missingBuiltInMicrophone
    }

    selectedInputID = builtIn.uid
    try session.setPreferredInput(builtIn)
  }

  private func refreshRoute() {
    let route = session.currentRoute
    activeInputName = route.inputs.map(\.portName).joined(separator: ", ")
    if activeInputName.isEmpty {
      activeInputName = "No Input"
    }

    outputRouteName = route.outputs.map(\.portName).joined(separator: ", ")
    if outputRouteName.isEmpty {
      outputRouteName = "System Output"
    }

    isHeadphoneOutput = route.outputs.contains { port in
      switch port.portType {
      case .headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .usbAudio:
        return true
      default:
        return false
      }
    }
  }

  private func startMeteringTask() {
    meteringTask?.cancel()
    meteringTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        guard let self, let recorder = self.recorder, self.isRecording else { return }
        recorder.updateMeters()
        self.audioLevel = Self.normalizedPower(recorder.averagePower(forChannel: 0))
        self.recordingDuration = recorder.currentTime
        try? await Task.sleep(for: .milliseconds(80))
      }
    }
  }

  private func startPlaybackTask() {
    playbackTask?.cancel()
    playbackTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        guard let self, let player = self.player else { return }

        if player.duration > 0 {
          self.playbackProgress = min(max(player.currentTime / player.duration, 0), 1)
        }

        if player.isPlaying == false {
          self.player = nil
          self.isPlaying = false
          self.playbackProgress = 0
          self.restoreDiscoverySessionIfIdle()
          return
        }

        try? await Task.sleep(for: .milliseconds(100))
      }
    }
  }

  private func setError(_ error: any Error) {
    errorMessage = error.localizedDescription
    isRecording = false
    isPlaying = false
    isMonitoring = false
    audioLevel = 0
  }

  private func restoreDiscoverySessionIfIdle() {
    guard isRecording == false, isPlaying == false, isMonitoring == false else { return }

    do {
      try configureDiscoverySession()
      refreshAudioInputs()
    } catch {
      refreshRoute()
    }
  }

  private func removeFileIfNeeded(at url: URL) {
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    try? FileManager.default.removeItem(at: url)
  }

  private var recordingURL: URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("mu-voice-recorder-current.m4a")
  }

  private static func normalizedPower(_ power: Float) -> Float {
    let clamped = max(power, -60)
    return min(max((clamped + 60) / 60, 0), 1)
  }

  private static func durationText(_ duration: TimeInterval) -> String {
    let totalSeconds = max(Int(duration.rounded()), 0)
    return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
  }
}
