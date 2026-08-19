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
  #endif
}

/// Failures that prevent CaptureAudio from starting on its requested input.
enum AudioRecordingSessionError: LocalizedError, Sendable {
  case noRecordingInputAvailable
  case requestedInputDidNotBecomeActive(name: String)
  case recorderDidNotStart

  var errorDescription: String? {
    switch self {
    case .noRecordingInputAvailable:
      return "No recording input is currently available."
    case .requestedInputDidNotBecomeActive(let name):
      return "The selected microphone “\(name)” didn't become active. "
        + "Check its connection and try again."
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
  /// controller a bounded confirmation window before it either starts the
  /// recorder on the requested input or reports an actionable failure.
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
    /// Allows Bluetooth profile transitions up to roughly 1.5 seconds without
    /// ever starting the recorder on an unconfirmed fallback microphone.
    private static let routeConfirmationPolicy = AudioRecordingInputRouteConfirmationPolicy(
      maximumAttempts: 30
    )
    private static let routeConfirmationInterval: Duration = .milliseconds(50)
    private static let recorderRouteStabilizationDelay: Duration = .milliseconds(100)

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
          try Self.applyPreferredInput(
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
    func startRecording(
      fileURL: URL,
      selection: AudioRecordingInputSelection
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
          try Self.applyPreferredInput(
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

      var startedRecorder: AVAudioRecorder?
      do {
        _ = try await confirmRequestedInputRoute(routeRequest)
        let recorder = try await perform {
          try Self.makeRecorder(fileURL: fileURL)
        }
        startedRecorder = recorder
        // Starting audio I/O can perform one more system route reconfiguration.
        // Give that transition a moment to become observable before confirming.
        try await Task.sleep(for: Self.recorderRouteStabilizationDelay)
        let snapshot = try await verifyRequestedInputRemainsActive(routeRequest)
        return AudioRecordingStartResult(
          recorder: recorder,
          sessionSnapshot: snapshot
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
          recorder: try Self.makeRecorder(fileURL: fileURL)
        )
      }
    }
  #endif

  /// Refreshes metering and returns copied values for MainActor presentation.
  func meter(_ recorder: AVAudioRecorder) async -> AudioRecordingMeterReading? {
    try? await perform {
      guard recorder.isRecording else { return nil }
      recorder.updateMeters()
      return AudioRecordingMeterReading(
        averagePower: recorder.averagePower(forChannel: 0),
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

  private static func makeRecorder(fileURL: URL) throws -> AVAudioRecorder {
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVSampleRateKey: 44_100,
      AVNumberOfChannelsKey: 1,
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
    private func confirmRequestedInputRoute(
      _ request: AudioRecordingInputRouteRequest
    ) async throws -> AudioRecordingSessionSnapshot {
      guard let requestedInput = request.requestedInput else {
        throw AudioRecordingSessionError.noRecordingInputAvailable
      }

      for attemptIndex in 0..<Self.routeConfirmationPolicy.maximumAttempts {
        let activeInputIDs = try await perform {
          AVAudioSession.sharedInstance().currentRoute.inputs.map(\.uid)
        }
        switch Self.routeConfirmationPolicy.decision(
          requestedInputID: requestedInput.id,
          activeInputIDs: activeInputIDs,
          attemptIndex: attemptIndex
        ) {
        case .confirmed:
          return request.snapshot(resolvedInput: requestedInput)
        case .retry:
          try await Task.sleep(for: Self.routeConfirmationInterval)
        case .timedOut:
          throw AudioRecordingSessionError.requestedInputDidNotBecomeActive(
            name: requestedInput.name
          )
        }
      }

      preconditionFailure("The route confirmation policy must finish within its attempt limit.")
    }

    /// Rejects a recorder start that reconfigured audio I/O onto another input.
    private func verifyRequestedInputRemainsActive(
      _ request: AudioRecordingInputRouteRequest
    ) async throws -> AudioRecordingSessionSnapshot {
      guard let requestedInput = request.requestedInput else {
        throw AudioRecordingSessionError.noRecordingInputAvailable
      }
      let isRequestedInputActive = try await perform {
        AVAudioSession.sharedInstance().currentRoute.inputs.contains {
          $0.uid == requestedInput.id
        }
      }
      guard isRequestedInputActive else {
        throw AudioRecordingSessionError.requestedInputDidNotBecomeActive(
          name: requestedInput.name
        )
      }
      return request.snapshot(resolvedInput: requestedInput)
    }

    /// Avoids emitting another route/input notification when the recording
    /// configuration is already active.
    private static func configureForRecordingIfNeeded(
      _ session: AVAudioSession
    ) throws {
      let options: AVAudioSession.CategoryOptions = [.allowBluetoothHFP]
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
    /// stale. Recording start forces one fresh request after activation.
    private static func applyPreferredInput(
      _ request: AudioRecordingInputRouteRequest,
      to session: AVAudioSession,
      forceRequest: Bool
    ) throws {
      let ports = session.availableInputs ?? []
      let preferredPort = ports.first { $0.uid == request.requestedInput?.id }

      guard let requestedInput = request.requestedInput else {
        if session.preferredInput != nil {
          try session.setPreferredInput(nil)
        }
        return
      }
      guard let preferredPort else {
        throw AudioRecordingSessionError.requestedInputDidNotBecomeActive(
          name: requestedInput.name
        )
      }

      let isRequestedInputActive = session.currentRoute.inputs.contains {
        $0.uid == requestedInput.id
      }
      if forceRequest
        || session.preferredInput?.uid != requestedInput.id
        || isRequestedInputActive == false
      {
        try session.setPreferredInput(preferredPort)
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
      if session.preferredInput != nil {
        try? session.setPreferredInput(nil)
      }
      try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }
  #endif
}
