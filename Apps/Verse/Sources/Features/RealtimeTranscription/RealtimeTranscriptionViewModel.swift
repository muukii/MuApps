import Foundation
@preconcurrency import AVFoundation
import Speech

@Observable
@MainActor
final class RealtimeTranscriptionViewModel {

  enum Status {
    case idle
    case preparing
    case ready
    case recording
    case error(String)

    var displayText: String {
      switch self {
      case .idle:
        return "Initializing..."
      case .preparing:
        return "Preparing speech model..."
      case .ready:
        return "Ready to record"
      case .recording:
        return "Recording..."
      case .error(let message):
        return "Error: \(message)"
      }
    }
  }

  // MARK: - Published State

  private(set) var status: Status = .idle
  private(set) var transcriptions: [TranscriptionItem] = []
  private(set) var partialTranscription: String?
  private(set) var audioLevel: Float = -60
  private(set) var isRecording = false

  var canRecord: Bool {
    if case .ready = status { return true }
    if case .recording = status { return true }
    return false
  }

  var exportText: String {
    transcriptions.map { item in
      "[\(item.formattedTime)] \(String(item.text.characters))"
    }.joined(separator: "\n\n")
  }

  // MARK: - Session Persistence

  private let sessionService: TranscriptionSessionService
  private var currentSession: TranscriptionSession?
  private var recordingStartTime: Date?

  init(sessionService: TranscriptionSessionService) {
    self.sessionService = sessionService
  }

  // MARK: - Private Properties

  private var audioEngine: AVAudioEngine?
  private var speechAnalyzer: SpeechAnalyzer?
  private var transcriber: SpeechTranscriber?
  private var resultsTask: Task<Void, Never>?
  private var analysisTask: Task<Void, any Error>?
  private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?

  // MARK: - Public Methods

  func prepareIfNeeded() async {
    guard case .idle = status else { return }

    // Check availability
    guard SpeechTranscriber.isAvailable else {
      status = .error("Not available on Simulator")
      return
    }

    // Get supported locale
    let locale = Locale(identifier: "en_US")
    guard let supportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
      status = .error("Language not supported")
      return
    }

    // Create transcriber
    let transcriber = SpeechTranscriber(
      locale: supportedLocale,
      transcriptionOptions: [],
      reportingOptions: [],
      attributeOptions: [.audioTimeRange]
    )
    self.transcriber = transcriber

    // Install assets if needed
    status = .preparing
    do {
      if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
        try await request.downloadAndInstall()
      }
    } catch {
      status = .error("Model download failed")
      return
    }

    status = .ready
  }

  func startRecording() async {
    guard let transcriber else { return }

    // Request microphone permission
    let authorized = await AVAudioApplication.requestRecordPermission()
    guard authorized else {
      status = .error("Microphone access denied")
      return
    }

    // Configure audio session
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playAndRecord, mode: .measurement, options: .duckOthers)
      try session.setActive(true)
    } catch {
      status = .error("Audio session failed")
      return
    }

    // Setup audio engine
    let engine = AVAudioEngine()
    self.audioEngine = engine

    let inputNode = engine.inputNode
    let inputFormat = inputNode.outputFormat(forBus: 0)

    // Create 16-bit PCM format at 16kHz required by SpeechAnalyzer
    // Note: Offline transcription models typically require 16kHz sample rate
    let targetSampleRate: Double = 16000
    guard let pcmFormat = AVAudioFormat(
      commonFormat: .pcmFormatInt16,
      sampleRate: targetSampleRate,
      channels: 1,
      interleaved: true
    ) else {
      status = .error("Failed to create audio format")
      return
    }

    // Create audio converter
    guard let converter = AVAudioConverter(from: inputFormat, to: pcmFormat) else {
      status = .error("Failed to create audio converter")
      return
    }

    // Create analyzer
    let analyzer = SpeechAnalyzer(modules: [transcriber])
    self.speechAnalyzer = analyzer

    // Create input stream for analyzer (using AsyncStream.makeStream pattern from docs)
    let (inputSequence, inputBuilder) = AsyncStream.makeStream(of: AnalyzerInput.self)
    self.inputContinuation = inputBuilder

    // Create a new session for this recording
    do {
      currentSession = try sessionService.createSession()
      recordingStartTime = Date()
    } catch {
      print("Failed to create session: \(error)")
    }

    // Start collecting results
    resultsTask = Task { @MainActor in
      do {
        for try await result in transcriber.results {
          let attributedText = result.text
          if !attributedText.characters.isEmpty {
            let item = TranscriptionItem(text: attributedText, timestamp: Date())
            transcriptions.append(item)
            partialTranscription = nil

            // Save entry to current session
            if let session = currentSession {
              do {
                try sessionService.addEntry(
                  to: session,
                  text: item.plainText,
                  timestamp: item.timestamp,
                  wordTimings: item.wordTimings
                )
              } catch {
                print("Failed to save entry: \(error)")
              }
            }
          }
        }
      } catch {
        print("Results stream error: \(error)")
      }
    }

    // Start analysis task
    analysisTask = Task {
      do {
        let lastTime = try await analyzer.analyzeSequence(inputSequence)
        if let lastTime {
          try await analyzer.finalizeAndFinish(through: lastTime)
        }
      } catch {
        print("Analysis error: \(error)")
      }
    }

    // Install audio tap to feed buffers to analyzer
    inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { @Sendable [weak self] buffer, _ in
      guard let self else { return }

      // Update audio level on main thread
      Task { @MainActor in
        self.updateAudioLevel(buffer: buffer)
      }

      // Convert to 16-bit PCM format required by SpeechAnalyzer
      let frameCount = AVAudioFrameCount(pcmFormat.sampleRate * Double(buffer.frameLength) / inputFormat.sampleRate)
      guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: frameCount) else {
        return
      }

      var error: NSError?
      converter.convert(to: convertedBuffer, error: &error) { inNumPackets, outStatus in
        outStatus.pointee = .haveData
        return buffer
      }

      if error == nil {
        // Feed converted buffer to analyzer via input stream
        let input = AnalyzerInput(buffer: convertedBuffer)
        self.inputContinuation?.yield(input)
      }
    }

    // Start engine
    do {
      try engine.start()
      isRecording = true
      status = .recording
    } catch {
      status = .error("Audio engine failed")
    }
  }

  func stopRecording() async {
    // Stop engine first
    audioEngine?.inputNode.removeTap(onBus: 0)
    audioEngine?.stop()
    audioEngine = nil

    // Finish input stream (this signals end of audio)
    inputContinuation?.finish()
    inputContinuation = nil

    // Wait for analysis to complete
    _ = try? await analysisTask?.value
    analysisTask = nil

    speechAnalyzer = nil

    // Cancel results task
    resultsTask?.cancel()
    resultsTask = nil

    // Finalize session
    if let session = currentSession {
      if session.entries.isEmpty {
        // Delete empty session
        do {
          try sessionService.deleteSession(session)
        } catch {
          print("Failed to delete empty session: \(error)")
        }
      } else {
        // Save duration
        let duration = Date().timeIntervalSince(recordingStartTime ?? Date())
        do {
          try sessionService.finalizeSession(session, duration: duration)
        } catch {
          print("Failed to finalize session: \(error)")
        }
      }
      currentSession = nil
      recordingStartTime = nil
    }

    // Deactivate audio session to restore normal audio behavior
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setActive(false, options: .notifyOthersOnDeactivation)
    } catch {
      print("Failed to deactivate audio session: \(error)")
    }

    isRecording = false
    status = .ready
    audioLevel = -60
  }

  func clearTranscriptions() {
    transcriptions.removeAll()
    partialTranscription = nil
  }

  // MARK: - Private Methods

  private func updateAudioLevel(buffer: AVAudioPCMBuffer) {
    guard let channelData = buffer.floatChannelData?[0] else { return }
    let frameLength = Int(buffer.frameLength)

    var sum: Float = 0
    for i in 0..<frameLength {
      let sample = channelData[i]
      sum += sample * sample
    }

    let rms = sqrt(sum / Float(frameLength))
    let db = 20 * log10(max(rms, 0.000001))

    audioLevel = db
  }
}
