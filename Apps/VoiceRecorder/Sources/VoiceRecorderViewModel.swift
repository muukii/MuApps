import Foundation
import Observation
@preconcurrency import AVFoundation
import Speech

enum TranscriptionStatus: Equatable {
  case idle
  case preparing
  case ready
  case listening
  case unavailable(String)

  var displayText: String {
    switch self {
    case .idle:
      return "Transcript idle"
    case .preparing:
      return "Preparing speech model"
    case .ready:
      return "Transcript ready"
    case .listening:
      return "Listening"
    case .unavailable:
      return "Transcript unavailable"
    }
  }

  var detailText: String {
    switch self {
    case .idle:
      return "Speech model is not ready yet."
    case .preparing:
      return "Preparing live transcription."
    case .ready:
      return "Start streaming to show temporary captions."
    case .listening:
      return "Recent words fade out automatically."
    case .unavailable(let message):
      return message
    }
  }
}

struct LiveTranscriptItem: Identifiable, Equatable {
  let id = UUID()
  let text: String
  let createdAt: Date
  let expiresAt: Date

  func dissolveProgress(now: Date) -> Double {
    let total = max(expiresAt.timeIntervalSince(createdAt), 0.1)
    let elapsed = min(max(now.timeIntervalSince(createdAt), 0), total)
    let rawProgress = elapsed / total
    return min(max((rawProgress - 0.48) / 0.52, 0), 1)
  }

  func isExpired(now: Date) -> Bool {
    now >= expiresAt
  }
}

private struct TranscriptionPipeline: @unchecked Sendable {
  let converter: AVAudioConverter
  let outputFormat: AVAudioFormat
  let continuation: AsyncStream<AnalyzerInput>.Continuation
}

@Observable
@MainActor
final class VoiceRecorderViewModel {
  private let session = AVAudioSession.sharedInstance()
  private var inputPorts: [AVAudioSessionPortDescription] = []
  private var streamEngine: AVAudioEngine?
  private var streamCenterMixer: AVAudioMixerNode?
  private var delayNode: AVAudioUnitDelay?
  private var durationTask: Task<Void, Never>?
  private var streamStartedAt: Date?
  private var speechAnalyzer: SpeechAnalyzer?
  private var transcriber: SpeechTranscriber?
  private var transcriptionResultsTask: Task<Void, Never>?
  private var transcriptionAnalysisTask: Task<Void, any Error>?
  private var transcriptCleanupTask: Task<Void, Never>?
  private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?

  private(set) var inputDevices: [AudioInputDevice] = []
  var selectedInputID = ""

  private(set) var isPrepared = false
  private(set) var isPermissionDenied = false
  private(set) var isStreaming = false
  private(set) var audioLevel: Float = 0
  private(set) var streamDuration: TimeInterval = 0
  private(set) var outputRouteName = "System Output"
  private(set) var activeInputName = "No Input"
  private(set) var isHeadphoneOutput = false
  private(set) var errorMessage: String?
  private(set) var transcriptionStatus: TranscriptionStatus = .idle
  private(set) var transcriptItems: [LiveTranscriptItem] = []

  private let transcriptLifetime: TimeInterval = 8

  var monitorDelay: Double = 0.65 {
    didSet {
      delayNode?.delayTime = monitorDelay
    }
  }

  var canSelectInput: Bool {
    !isStreaming
  }

  var selectedInputName: String {
    inputDevices.first(where: { $0.id == selectedInputID })?.name ?? "Device Microphone"
  }

  var streamDurationText: String {
    Self.durationText(streamDuration)
  }

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
      await prepareTranscriptionIfNeeded()
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

  func toggleStreaming() async {
    if isStreaming {
      stopStreaming()
    } else {
      await startStreaming()
    }
  }

  func stopAll() {
    stopStreaming()
  }

  private func startStreaming() async {
    guard await ensurePermission() else { return }

    stopStreaming(restoreDiscovery: false)
    errorMessage = nil

    do {
      try configureStreamingSession()

      let engine = AVAudioEngine()
      let centerMixer = AVAudioMixerNode()
      let delay = AVAudioUnitDelay()
      delay.delayTime = monitorDelay
      delay.feedback = 0
      delay.lowPassCutoff = 22_050
      delay.wetDryMix = 100

      engine.attach(centerMixer)
      engine.attach(delay)

      let inputNode = engine.inputNode
      let inputFormat = inputNode.outputFormat(forBus: 0)
      let centeredStreamFormat = AVAudioFormat(
        standardFormatWithSampleRate: inputFormat.sampleRate,
        channels: 1
      )
      engine.connect(inputNode, to: centerMixer, format: inputFormat)
      engine.connect(centerMixer, to: delay, format: centeredStreamFormat)
      engine.connect(delay, to: engine.mainMixerNode, format: centeredStreamFormat)

      let transcriptionPipeline = startTranscriptionPipeline(inputFormat: inputFormat)

      inputNode.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { @Sendable [weak self] buffer, _ in
        let level = Self.normalizedPower(from: buffer)

        Task { @MainActor [weak self] in
          guard let self, self.isStreaming else { return }
          self.audioLevel = level
        }

        if let transcriptionPipeline {
          Self.feedTranscription(buffer: buffer, pipeline: transcriptionPipeline)
        }
      }

      try engine.start()

      streamEngine = engine
      streamCenterMixer = centerMixer
      delayNode = delay
      streamStartedAt = Date()
      streamDuration = 0
      audioLevel = 0
      isStreaming = true
      startDurationTask()
      refreshRoute()
    } catch {
      setError(error)
    }
  }

  private func stopStreaming(restoreDiscovery: Bool = true) {
    durationTask?.cancel()
    durationTask = nil
    stopTranscriptionPipeline()

    if let streamEngine {
      streamEngine.inputNode.removeTap(onBus: 0)
      streamEngine.stop()
      streamEngine.reset()
    }

    self.streamEngine = nil
    streamCenterMixer = nil
    delayNode = nil
    streamStartedAt = nil
    isStreaming = false
    audioLevel = 0

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

  private func prepareTranscriptionIfNeeded() async {
    guard transcriptionStatus == .idle else { return }

    guard SpeechTranscriber.isAvailable else {
      transcriptionStatus = .unavailable("SpeechAnalyzer is not available on this device.")
      return
    }

    let locale = Locale.autoupdatingCurrent
    guard let supportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
      transcriptionStatus = .unavailable("Live transcription does not support the current language.")
      return
    }

    let transcriber = SpeechTranscriber(
      locale: supportedLocale,
      transcriptionOptions: [],
      reportingOptions: [],
      attributeOptions: []
    )
    self.transcriber = transcriber

    transcriptionStatus = .preparing
    do {
      if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
        try await request.downloadAndInstall()
      }
      transcriptionStatus = .ready
    } catch {
      transcriptionStatus = .unavailable("Speech model could not be prepared.")
    }
  }

  private func startTranscriptionPipeline(inputFormat: AVAudioFormat) -> TranscriptionPipeline? {
    guard let transcriber else { return nil }

    guard let outputFormat = AVAudioFormat(
      commonFormat: .pcmFormatInt16,
      sampleRate: 16_000,
      channels: 1,
      interleaved: true
    ) else {
      transcriptionStatus = .unavailable("Speech input format could not be created.")
      return nil
    }

    guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
      transcriptionStatus = .unavailable("Speech input converter could not be created.")
      return nil
    }

    let analyzer = SpeechAnalyzer(modules: [transcriber])
    speechAnalyzer = analyzer

    let (inputSequence, inputBuilder) = AsyncStream.makeStream(of: AnalyzerInput.self)
    inputContinuation = inputBuilder

    transcriptionResultsTask = Task { @MainActor [weak self] in
      do {
        for try await result in transcriber.results {
          guard let self else { return }
          self.appendTranscript(text: String(result.text.characters))
        }
      } catch {
        print("Transcription results error: \(error)")
      }
    }

    transcriptionAnalysisTask = Task {
      do {
        let lastTime = try await analyzer.analyzeSequence(inputSequence)
        if let lastTime {
          try await analyzer.finalizeAndFinish(through: lastTime)
        }
      } catch {
        print("Speech analysis error: \(error)")
      }
    }

    transcriptionStatus = .listening
    startTranscriptCleanupTask()

    return TranscriptionPipeline(
      converter: converter,
      outputFormat: outputFormat,
      continuation: inputBuilder
    )
  }

  private func stopTranscriptionPipeline() {
    inputContinuation?.finish()
    inputContinuation = nil

    transcriptionAnalysisTask?.cancel()
    transcriptionAnalysisTask = nil

    transcriptionResultsTask?.cancel()
    transcriptionResultsTask = nil

    transcriptCleanupTask?.cancel()
    transcriptCleanupTask = nil

    speechAnalyzer = nil

    if transcriptionStatus == .listening {
      transcriptionStatus = transcriber == nil ? .idle : .ready
    }
  }

  private func configureDiscoverySession() throws {
    try session.setCategory(
      .playAndRecord,
      mode: .default,
      options: [.allowBluetoothHFP, .allowBluetoothA2DP]
    )
    try session.setActive(true)
  }

  private func configureStreamingSession() throws {
    try session.setCategory(
      .playAndRecord,
      mode: .measurement,
      options: [.allowBluetoothHFP, .allowBluetoothA2DP]
    )
    try? session.setPreferredIOBufferDuration(0.005)
    try session.setActive(true)
    try applyPreferredInput(id: selectedInputID)
  }

  private func applyPreferredInput(id: String) throws {
    guard let port = inputPorts.first(where: { $0.uid == id }) else { return }
    try session.setPreferredInput(port)
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

  private func startDurationTask() {
    durationTask?.cancel()
    durationTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        guard let self, self.isStreaming, let streamStartedAt = self.streamStartedAt else { return }
        self.streamDuration = Date().timeIntervalSince(streamStartedAt)
        try? await Task.sleep(for: .milliseconds(100))
      }
    }
  }

  private func setError(_ error: any Error) {
    stopStreaming(restoreDiscovery: false)
    errorMessage = error.localizedDescription
  }

  private func restoreDiscoverySessionIfIdle() {
    guard isStreaming == false else { return }

    do {
      try configureDiscoverySession()
      refreshAudioInputs()
    } catch {
      refreshRoute()
    }
  }

  private func appendTranscript(text: String) {
    let plainText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard plainText.isEmpty == false else { return }
    guard transcriptItems.last?.text != plainText else { return }

    let now = Date()
    let item = LiveTranscriptItem(
      text: plainText,
      createdAt: now,
      expiresAt: now.addingTimeInterval(transcriptLifetime)
    )
    transcriptItems.append(item)
    removeExpiredTranscriptItems(now: now)
  }

  private func startTranscriptCleanupTask() {
    transcriptCleanupTask?.cancel()
    transcriptCleanupTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        self?.removeExpiredTranscriptItems(now: Date())
        try? await Task.sleep(for: .milliseconds(250))
      }
    }
  }

  private func removeExpiredTranscriptItems(now: Date) {
    transcriptItems.removeAll { $0.isExpired(now: now) }
  }

  nonisolated private static func feedTranscription(buffer: AVAudioPCMBuffer, pipeline: TranscriptionPipeline) {
    let outputFrameCount = AVAudioFrameCount(
      pipeline.outputFormat.sampleRate * Double(buffer.frameLength) / buffer.format.sampleRate
    )
    guard let convertedBuffer = AVAudioPCMBuffer(
      pcmFormat: pipeline.outputFormat,
      frameCapacity: max(outputFrameCount, 1)
    ) else {
      return
    }

    var conversionError: NSError?
    pipeline.converter.convert(to: convertedBuffer, error: &conversionError) { _, outStatus in
      outStatus.pointee = .haveData
      return buffer
    }

    guard conversionError == nil else { return }

    pipeline.continuation.yield(AnalyzerInput(buffer: convertedBuffer))
  }

  nonisolated private static func normalizedPower(from buffer: AVAudioPCMBuffer) -> Float {
    guard let channelData = buffer.floatChannelData else { return 0 }

    let frameLength = Int(buffer.frameLength)
    let channelCount = Int(buffer.format.channelCount)
    guard frameLength > 0, channelCount > 0 else { return 0 }

    var sum: Float = 0
    for channel in 0..<channelCount {
      let samples = channelData[channel]
      for frame in 0..<frameLength {
        let sample = samples[frame]
        sum += sample * sample
      }
    }

    let mean = sum / Float(frameLength * channelCount)
    let rms = sqrt(mean)
    let decibels = 20 * log10(max(rms, 0.000_001))
    return normalizedPower(decibels)
  }

  nonisolated private static func normalizedPower(_ power: Float) -> Float {
    let clamped = max(power, -60)
    return min(max((clamped + 60) / 60, 0), 1)
  }

  nonisolated private static func durationText(_ duration: TimeInterval) -> String {
    let totalSeconds = max(Int(duration.rounded()), 0)
    return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
  }
}
