import AVFoundation
import Dispatch

/// One metering result copied from the recorder's serial execution context.
struct AudioRecordingMeterReading: Sendable, Equatable {
  let averagePower: Float
  let duration: TimeInterval
}

/// A recorder prepared and started away from MainActor.
struct AudioRecordingStartResult: Sendable {
  let recorder: AVAudioRecorder

  #if os(iOS)
    let sessionSnapshot: AudioRecordingSessionSnapshot

    /// The channel layout the recorder was actually configured with. Falls back
    /// to `.mono` when the requested stereo configuration was refused.
    let channelMode: AudioRecordingChannelMode
  #endif
}

/// Failures that prevent CaptureAudio from starting a recording.
enum AudioRecordingSessionError: LocalizedError, Sendable {
  case noRecordingInputAvailable
  case recorderDidNotStart

  var errorDescription: String? {
    switch self {
    case .noRecordingInputAvailable:
      return "No recording input is currently available."
    case .recorderDidNotStart:
      return "The audio recorder couldn't start."
    }
  }
}

#if os(iOS)
  /// A value snapshot copied from the process-wide iOS audio session.
  ///
  /// CaptureAudio publishes only these `Sendable` values to MainActor. The live
  /// `AVAudioSession` and its port objects stay on the controller's serial queue.
  struct AudioRecordingSessionSnapshot: Sendable, Equatable {
    let availableInputs: [AudioRecordingInput]
    let selection: AudioRecordingInputSelection
    let resolvedInput: AudioRecordingInput?
  }

  /// One value-only request to route recording through a resolved input.
  private struct AudioRecordingInputRouteRequest: Sendable {
    let availableInputs: [AudioRecordingInput]
    let selection: AudioRecordingInputSelection
    let requestedInput: AudioRecordingInput?

    func snapshot(resolvedInput: AudioRecordingInput?) -> AudioRecordingSessionSnapshot {
      AudioRecordingSessionSnapshot(
        availableInputs: availableInputs,
        selection: selection,
        resolvedInput: resolvedInput
      )
    }
  }

  /// Decides whether an asynchronous audio-route request is ready to record.
  ///
  /// `setPreferredInput(_:)` only requests a route change. This policy gives the
  /// controller a bounded confirmation window; on timeout the take proceeds on
  /// whatever route the system settled on rather than failing.
  struct AudioRecordingInputRouteConfirmationPolicy: Sendable {
    enum Decision: Sendable, Equatable {
      case confirmed
      case retry
      case timedOut
    }

    let maximumAttempts: Int

    init(maximumAttempts: Int) {
      precondition(maximumAttempts > 0)
      self.maximumAttempts = maximumAttempts
    }

    func decision(
      requestedInputID: AudioRecordingInput.ID,
      activeInputIDs: [AudioRecordingInput.ID],
      attemptIndex: Int
    ) -> Decision {
      precondition((0..<maximumAttempts).contains(attemptIndex))

      if activeInputIDs.contains(requestedInputID) {
        return .confirmed
      }
      if attemptIndex + 1 < maximumAttempts {
        return .retry
      }
      return .timedOut
    }
  }
#endif

/// Serializes potentially blocking recorder and audio-session work away from MainActor.
///
/// The selected SDK exposes only synchronous session activation on iOS. The
/// recorder's start, stop, duration, and meter reads use the same queue because
/// AVFoundation can consult active-session state from those APIs as well.
final class AudioRecordingSessionController: Sendable {

  private let queue = DispatchQueue(
    label: "app.muukii.tinycurve.audio-recording-session",
    qos: .userInitiated
  )

  #if os(iOS)
    /// Allows Bluetooth profile transitions up to roughly 1.5 seconds before
    /// recording proceeds on the route the system actually settled on.
    private static let routeConfirmationPolicy = AudioRecordingInputRouteConfirmationPolicy(
      maximumAttempts: 30
    )
    private static let routeConfirmationInterval: Duration = .milliseconds(50)
    private static let recorderRouteStabilizationDelay: Duration = .milliseconds(100)

    /// Bounds the wait for the session to report two input channels after a
    /// stereo data-source request (up to ~500ms).
    private static let stereoInputConfirmationAttempts = 10

    /// Prepares or refreshes input state without activating the audio session.
    func refresh(
      selection: AudioRecordingInputSelection,
      applyingPreferredInput: Bool
    ) async throws -> AudioRecordingSessionSnapshot {
      try await perform {
        let session = AVAudioSession.sharedInstance()
        try Self.configureForRecordingIfNeeded(session)
        let request = Self.makeInputRouteRequest(
          from: session,
          selection: selection
        )
        if applyingPreferredInput {
          Self.applyPreferredInput(
            request,
            to: session,
            forceRequest: false
          )
        }
        let resolvedInput =
          applyingPreferredInput
          ? Self.currentInput(from: request, session: session)
          : request.requestedInput
        return request.snapshot(resolvedInput: resolvedInput)
      }
    }

    /// Configures the selected input, activates the session, and starts recording.
    ///
    /// Routing is best-effort: after a bounded wait for the requested input the
    /// recorder starts on the active route, and the snapshot reports the input
    /// that is actually recording. A take never fails because a Bluetooth
    /// microphone was slow to hand over or declined the route.
    func startRecording(
      fileURL: URL,
      selection: AudioRecordingInputSelection,
      channelMode: AudioRecordingChannelMode,
      inputOrientation: AVAudioSession.StereoOrientation
    ) async throws -> AudioRecordingStartResult {
      let routeRequest = try await perform {
        let session = AVAudioSession.sharedInstance()
        var didActivateSession = false

        do {
          try Self.configureForRecordingIfNeeded(session)
          try session.setActive(true)
          didActivateSession = true

          let request = Self.makeInputRouteRequest(
            from: session,
            selection: selection
          )
          guard request.requestedInput != nil else {
            throw AudioRecordingSessionError.noRecordingInputAvailable
          }
          Self.applyPreferredInput(
            request,
            to: session,
            forceRequest: true
          )
          return request
        } catch {
          if didActivateSession {
            Self.deactivate(session)
          }
          throw error
        }
      }

      await waitForRequestedInputRoute(routeRequest)

      var startedRecorder: AVAudioRecorder?
      do {
        var resolvedChannelMode = try await perform {
          Self.configureChannelMode(
            channelMode,
            on: AVAudioSession.sharedInstance(),
            request: routeRequest,
            inputOrientation: inputOrientation
          )
        }
        if resolvedChannelMode.channelCount == 2 {
          // WWDC20 session 10226: the active session, not the capability list,
          // is the authority on whether stereo was actually granted — an app
          // controlling routing can deny the preference. The data-source
          // request also needs a moment to reconfigure the route, so poll
          // briefly before recording a mono take instead.
          let hasStereoInput = await waitForStereoInputChannels()
          if hasStereoInput == false {
            resolvedChannelMode = .mono
          }
        }
        let channelCount = resolvedChannelMode.channelCount
        let recorder = try await perform {
          try Self.makeRecorder(
            fileURL: fileURL,
            channelCount: channelCount
          )
        }
        startedRecorder = recorder
        // Starting audio I/O can perform one more system route reconfiguration.
        // Give that transition a moment to become observable before reporting
        // the input that is actually recording.
        try await Task.sleep(for: Self.recorderRouteStabilizationDelay)
        let snapshot = try await perform {
          let session = AVAudioSession.sharedInstance()
          return routeRequest.snapshot(
            resolvedInput: Self.currentInput(from: routeRequest, session: session)
          )
        }
        return AudioRecordingStartResult(
          recorder: recorder,
          sessionSnapshot: snapshot,
          channelMode: resolvedChannelMode
        )
      } catch {
        let recorderToStop = startedRecorder
        _ = try? await perform {
          recorderToStop?.stop()
          Self.deactivate(AVAudioSession.sharedInstance())
        }
        throw error
      }
    }
  #else
    /// Starts a native macOS recorder on the controller's serial queue.
    func startRecording(fileURL: URL) async throws -> AudioRecordingStartResult {
      try await perform {
        AudioRecordingStartResult(
          recorder: try Self.makeRecorder(fileURL: fileURL, channelCount: 1)
        )
      }
    }
  #endif

  /// Refreshes metering and returns copied values for MainActor presentation.
  func meter(_ recorder: AVAudioRecorder) async -> AudioRecordingMeterReading? {
    try? await perform {
      guard recorder.isRecording else { return nil }
      recorder.updateMeters()
      // The waveform renders one stream, so the louder channel drives the
      // meter; a stereo take with one quiet channel still shows motion.
      let channelCount = max(1, Int(recorder.format.channelCount))
      let averagePower =
        (0..<channelCount)
        .map { recorder.averagePower(forChannel: $0) }
        .max() ?? -160
      return AudioRecordingMeterReading(
        averagePower: averagePower,
        duration: recorder.currentTime
      )
    }
  }

  /// Stops and closes the recorder before releasing the iOS audio session.
  func stopRecording(_ recorder: AVAudioRecorder) async -> TimeInterval {
    (try? await perform {
      let finalDuration = recorder.currentTime
      recorder.stop()

      #if os(iOS)
        Self.deactivate(AVAudioSession.sharedInstance())
      #endif

      return finalDuration
    }) ?? 0
  }

  private func perform<Output: Sendable>(
    _ operation: @escaping @Sendable () throws -> Output
  ) async throws -> Output {
    try await withCheckedThrowingContinuation { continuation in
      queue.async {
        do {
          continuation.resume(returning: try operation())
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  private static func makeRecorder(
    fileURL: URL,
    channelCount: Int
  ) throws -> AVAudioRecorder {
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVSampleRateKey: 44_100,
      AVNumberOfChannelsKey: channelCount,
      AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
    ]
    let recorder = try AVAudioRecorder(url: fileURL, settings: settings)
    recorder.isMeteringEnabled = true
    guard recorder.record() else {
      throw AudioRecordingSessionError.recorderDidNotStart
    }
    return recorder
  }

  #if os(iOS)
    /// Waits for `setPreferredInput(_:)` to take effect. A timeout is not a
    /// failure: the caller records on the active route and the UI shows the
    /// resolved input instead of the requested one.
    private func waitForRequestedInputRoute(
      _ request: AudioRecordingInputRouteRequest
    ) async {
      guard let requestedInput = request.requestedInput else { return }

      for attemptIndex in 0..<Self.routeConfirmationPolicy.maximumAttempts {
        let activeInputIDs =
          (try? await perform {
            AVAudioSession.sharedInstance().currentRoute.inputs.map(\.uid)
          }) ?? []
        switch Self.routeConfirmationPolicy.decision(
          requestedInputID: requestedInput.id,
          activeInputIDs: activeInputIDs,
          attemptIndex: attemptIndex
        ) {
        case .confirmed, .timedOut:
          return
        case .retry:
          do {
            try await Task.sleep(for: Self.routeConfirmationInterval)
          } catch {
            return
          }
        }
      }
    }

    /// Waits for the active session to expose two input channels after the
    /// stereo data source was requested. `false` means the system kept a mono
    /// input and the recorder must be created with one channel.
    private func waitForStereoInputChannels() async -> Bool {
      for _ in 0..<Self.stereoInputConfirmationAttempts {
        let channelCount =
          (try? await perform {
            AVAudioSession.sharedInstance().inputNumberOfChannels
          }) ?? 1
        if channelCount >= 2 {
          return true
        }
        do {
          try await Task.sleep(for: Self.routeConfirmationInterval)
        } catch {
          return false
        }
      }
      return false
    }

    /// Applies the built-in microphone data source, polar pattern, and input
    /// orientation for a stereo take, falling back to mono when the hardware or
    /// session refuses. Input orientation cannot change once recording starts,
    /// so this must run before the recorder is created.
    private static func configureChannelMode(
      _ requestedMode: AudioRecordingChannelMode,
      on session: AVAudioSession,
      request: AudioRecordingInputRouteRequest,
      inputOrientation: AVAudioSession.StereoOrientation
    ) -> AudioRecordingChannelMode {
      let ports = session.availableInputs ?? []
      guard let port = ports.first(where: { $0.uid == request.requestedInput?.id })
      else {
        return .mono
      }

      guard let dataSourceOrientation = requestedMode.dataSourceOrientation else {
        // Mono uses the default data source; clear a stereo one left behind by
        // a previous take so the bottom voice microphone records again.
        if port.preferredDataSource != nil {
          try? port.setPreferredDataSource(nil)
        }
        return .mono
      }

      guard
        let dataSource = (port.dataSources ?? []).first(where: {
          $0.orientation == dataSourceOrientation
        }),
        dataSource.supportedPolarPatterns?.contains(.stereo) == true
      else {
        return .mono
      }

      do {
        try dataSource.setPreferredPolarPattern(.stereo)
        try port.setPreferredDataSource(dataSource)
        try session.setPreferredInputOrientation(inputOrientation)
        return requestedMode
      } catch {
        return .mono
      }
    }

    /// Avoids emitting another route/input notification when the recording
    /// configuration is already active.
    private static func configureForRecordingIfNeeded(
      _ session: AVAudioSession
    ) throws {
      // High-quality Bluetooth recording upgrades supporting AirPods-class
      // devices past the telephone-grade HFP microphone; unsupported hardware
      // silently keeps using HFP.
      let options: AVAudioSession.CategoryOptions = [
        .allowBluetoothHFP,
        .bluetoothHighQualityRecording,
      ]
      guard
        session.category != .record
          || session.mode != .default
          || session.categoryOptions != options
      else { return }

      try session.setCategory(
        .record,
        mode: .default,
        options: options
      )
    }

    private static func makeInputRouteRequest(
      from session: AVAudioSession,
      selection: AudioRecordingInputSelection
    ) -> AudioRecordingInputRouteRequest {
      let ports = session.availableInputs ?? []
      let inputs = ports.map(AudioRecordingInput.init(port:))

      let effectiveSelection: AudioRecordingInputSelection
      switch selection {
      case .automatic:
        effectiveSelection = .automatic
      case .input(let id) where inputs.contains(where: { $0.id == id }):
        effectiveSelection = selection
      case .input:
        effectiveSelection = .automatic
      }

      let currentInputID = session.currentRoute.inputs.first?.uid
      let requestedInput = AudioRecordingInputSelectionPolicy.resolvedInput(
        for: effectiveSelection,
        availableInputs: inputs,
        currentInputID: currentInputID
      )

      return AudioRecordingInputRouteRequest(
        availableInputs: inputs,
        selection: effectiveSelection,
        requestedInput: requestedInput
      )
    }

    /// Requests the resolved port when either the preference or actual route is
    /// stale. Recording start forces one fresh request after activation. The
    /// request is best-effort; the active route stays authoritative.
    private static func applyPreferredInput(
      _ request: AudioRecordingInputRouteRequest,
      to session: AVAudioSession,
      forceRequest: Bool
    ) {
      let ports = session.availableInputs ?? []

      guard
        let requestedInput = request.requestedInput,
        let preferredPort = ports.first(where: { $0.uid == requestedInput.id })
      else {
        if session.preferredInput != nil {
          try? session.setPreferredInput(nil)
        }
        return
      }

      let isRequestedInputActive = session.currentRoute.inputs.contains {
        $0.uid == requestedInput.id
      }
      if forceRequest
        || session.preferredInput?.uid != requestedInput.id
        || isRequestedInputActive == false
      {
        try? session.setPreferredInput(preferredPort)
      }
    }

    private static func currentInput(
      from request: AudioRecordingInputRouteRequest,
      session: AVAudioSession
    ) -> AudioRecordingInput? {
      let activeInputIDs = Set(session.currentRoute.inputs.map(\.uid))
      return request.availableInputs.first { activeInputIDs.contains($0.id) }
        ?? request.requestedInput
    }

    private static func deactivate(_ session: AVAudioSession) {
      if let preferredInput = session.preferredInput {
        // Also clear a stereo data source so the next session starts from the
        // system default microphone configuration.
        if preferredInput.preferredDataSource != nil {
          try? preferredInput.setPreferredDataSource(nil)
        }
        try? session.setPreferredInput(nil)
      }
      try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }
  #endif
}
