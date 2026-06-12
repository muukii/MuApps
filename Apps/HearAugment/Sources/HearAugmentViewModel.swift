import Foundation
import Observation
@preconcurrency import AVFoundation

extension LowLevelEffectProcessorObjC: @unchecked Sendable {}

@Observable
@MainActor
final class HearAugmentViewModel {
  /// Microphone permission states that matter to the app's launch-to-listen
  /// flow. `requesting` is app-local because `AVAudioApplication` only stores
  /// the persisted system authorization result.
  private enum MicrophonePermissionState: Equatable {
    case undetermined
    case requesting
    case granted
    case denied
  }

  private enum AudioError: LocalizedError {
    case unavailableInputFormat
    case unavailableOutputFormat
    case engineDidNotStart
    case unavailableMicrophonePermission

    var errorDescription: String? {
      switch self {
      case .unavailableInputFormat:
        return "Microphone input is not available on this device."
      case .unavailableOutputFormat:
        return "The stereo listening format could not be created."
      case .engineDidNotStart:
        return "The listening engine could not be started."
      case .unavailableMicrophonePermission:
        return "Microphone permission is unavailable on this device."
      }
    }
  }

  private static let defaultPreset = AudioEffectChainPreset.builtIns[1]
  private let customPresetStoreKey = "HearAugment.CustomEffectChainPresets"
  private let audioBufferSizeStoreKey = "HearAugment.AudioBufferSize"
  private let maximumChainLength = 16
  private let headphoneRouteRequiredMessage = "Connect headphones or AirPods before starting live listening."
  private let headphoneRouteLostMessage = "Headphones or AirPods disconnected. Reconnect them before listening again."
  private let session = AVAudioSession.sharedInstance()
  private var inputPorts: [AVAudioSessionPortDescription] = []
  private var engine: AVAudioEngine?
  private var sourceNode: AVAudioSourceNode?
  private var environmentNode: AVAudioEnvironmentNode?
  private var effectProcessor: LowLevelEffectProcessorObjC?
  private var clockTask: Task<Void, Never>?
  private var isApplyingPreset = false
  private var shouldResumeAfterInterruption = false
  private var microphonePermissionState: MicrophonePermissionState = .undetermined

  private(set) var inputDevices: [AudioInputDevice] = []
  private(set) var customPresets: [AudioEffectChainPreset] = []
  private(set) var soloedEffectIDs: Set<UUID> = []
  private(set) var expandedEffectIDs: Set<UUID> = []
  private(set) var previewKind: AudioEffectKind?
  private let previewNodeID = UUID()
  var isBypassed: Bool = false {
    didSet {
      applyCurrentChain()
    }
  }
  var selectedAudioBufferSize: AudioBufferSizeOption = .balanced {
    didSet {
      persistAudioBufferSize()
    }
  }
  var selectedInputID = ""
  var selectedPresetID = HearAugmentViewModel.defaultPreset.id
  var effectChain: [AudioEffectNode] = HearAugmentViewModel.defaultPreset.nodes {
    didSet {
      if isApplyingPreset == false {
        selectedPresetID = ""
      }
      applyCurrentChain()
    }
  }

  var intensity: Double = 0.8 {
    didSet {
      applyCurrentChain()
    }
  }

  var outputLevel: Double = 0.72 {
    didSet {
      engine?.mainMixerNode.outputVolume = Float(outputLevel)
    }
  }

  var isAnySoloed: Bool {
    soloedEffectIDs.isEmpty == false
  }

  private(set) var isPrepared = false
  private(set) var isListening = false
  private(set) var elapsedTime: TimeInterval = 0
  private(set) var outputRouteName = "System Output"
  private(set) var activeInputName = "No Input"
  private(set) var isHeadphoneOutput = false
  private(set) var headphoneRouteMessage: String?
  private(set) var isHeadTrackedSpatialActive = false
  private(set) var errorMessage: String?
  private(set) var inputChannelCount: Int = 0

  init() {
    loadCustomPresets()
    loadAudioBufferSize()
  }

  var allPresets: [AudioEffectChainPreset] {
    AudioEffectChainPreset.builtIns + customPresets
  }

  var selectedPreset: AudioEffectChainPreset? {
    allPresets.first(where: { $0.id == selectedPresetID })
  }

  var selectedChainTitle: String {
    selectedPreset?.name ?? "Custom Chain"
  }

  var selectedChainSubtitle: String {
    let enabledCount = effectChain.filter(\.isEnabled).count
    return "\(enabledCount)/\(effectChain.count) effects enabled"
  }

  var canSelectInput: Bool {
    isListening == false
  }

  var canSelectAudioBufferSize: Bool {
    isListening == false
  }

  var isPermissionDenied: Bool {
    microphonePermissionState == .denied
  }

  var isPermissionRequesting: Bool {
    microphonePermissionState == .requesting
  }

  var isPermissionUndetermined: Bool {
    microphonePermissionState == .undetermined
  }

  var shouldRequireHeadphonesBeforeListening: Bool {
    isListening == false && isHeadphoneOutput == false
  }

  var canAddEffect: Bool {
    effectChain.count < maximumChainLength
  }

  var selectedInputName: String {
    inputDevices.first(where: { $0.id == selectedInputID })?.name ?? "Device Microphone"
  }

  var elapsedTimeText: String {
    Self.durationText(elapsedTime)
  }

  var audioBufferDescription: String {
    let sampleRate = session.sampleRate > 0 ? session.sampleRate : 48_000
    return "\(selectedAudioBufferSize.frameCount) frames / \(selectedAudioBufferSize.latencyText(sampleRate: sampleRate))"
  }

  var spatialAudioDescription: String {
    if isHeadTrackedSpatialActive {
      return "Head Tracked"
    }

    if shouldRequireHeadphonesBeforeListening {
      return "Connect Headphones"
    }

    return "Head Tracked Ready"
  }

  var inputChannelDescription: String {
    switch inputChannelCount {
    case 0: return "—"
    case 1: return "Mono"
    case 2: return "Stereo"
    default: return "\(inputChannelCount) ch"
    }
  }

  func prepare() async {
    errorMessage = nil
    synchronizeMicrophonePermission()

    guard microphonePermissionState == .granted else {
      if isListening {
        stopListening(restoreDiscovery: false)
      }
      isPrepared = false
      refreshRoute()
      return
    }

    if isListening {
      refreshAudioInputs()
      return
    }

    do {
      try configureDiscoverySession()
      refreshAudioInputs()
      isPrepared = true
    } catch {
      isPrepared = false
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

  func handleRouteChange() {
    let wasListening = isListening
    refreshAudioInputs()

    if isHeadphoneOutput {
      headphoneRouteMessage = nil
      return
    }

    guard wasListening else { return }
    stopListeningForMissingHeadphoneRoute()
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

  func selectPreset(id: String) {
    guard let preset = allPresets.first(where: { $0.id == id }) else { return }
    isApplyingPreset = true
    selectedPresetID = preset.id
    soloedEffectIDs.removeAll()
    expandedEffectIDs.removeAll()
    effectChain = preset.nodes
    isApplyingPreset = false
  }

  func addEffect(_ type: AudioEffectKind) {
    guard canAddEffect else { return }
    effectChain.append(AudioEffectNode(type: type))
  }

  func setPreview(kind: AudioEffectKind?) {
    guard previewKind != kind else { return }
    previewKind = kind
    applyCurrentChain()
  }

  func commitPreview() {
    guard let kind = previewKind, canAddEffect else { return }
    previewKind = nil
    effectChain.append(AudioEffectNode(type: kind))
  }

  func replaceEffect(_ node: AudioEffectNode) {
    guard let index = effectChain.firstIndex(where: { $0.id == node.id }) else { return }
    effectChain[index] = node
  }

  func removeEffect(id: UUID) {
    effectChain.removeAll { $0.id == id }
    soloedEffectIDs.remove(id)
    expandedEffectIDs.remove(id)
  }

  func moveEffect(id: UUID, offset: Int) {
    guard
      let sourceIndex = effectChain.firstIndex(where: { $0.id == id })
    else { return }

    let destinationIndex = sourceIndex + offset
    guard effectChain.indices.contains(destinationIndex) else { return }
    effectChain.swapAt(sourceIndex, destinationIndex)
  }

  func moveEffect(id: UUID, toIndex destinationIndex: Int) {
    guard let sourceIndex = effectChain.firstIndex(where: { $0.id == id }) else { return }
    let clampedDestination = min(max(destinationIndex, 0), effectChain.count - 1)
    guard clampedDestination != sourceIndex else { return }
    let node = effectChain.remove(at: sourceIndex)
    let insertIndex = min(max(clampedDestination, 0), effectChain.count)
    effectChain.insert(node, at: insertIndex)
  }

  func toggleSolo(id: UUID) {
    if soloedEffectIDs.contains(id) {
      soloedEffectIDs.remove(id)
    } else {
      soloedEffectIDs.insert(id)
    }
    applyCurrentChain()
  }

  func clearSolo() {
    guard soloedEffectIDs.isEmpty == false else { return }
    soloedEffectIDs.removeAll()
    applyCurrentChain()
  }

  func isSoloed(id: UUID) -> Bool {
    soloedEffectIDs.contains(id)
  }

  func toggleExpanded(id: UUID) {
    if expandedEffectIDs.contains(id) {
      expandedEffectIDs.remove(id)
    } else {
      expandedEffectIDs.insert(id)
    }
  }

  func isExpanded(id: UUID) -> Bool {
    expandedEffectIDs.contains(id)
  }

  func setBypass(_ bypassed: Bool) {
    guard isBypassed != bypassed else { return }
    isBypassed = bypassed
  }

  func saveCurrentChain(named rawName: String) {
    let trimmedName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
    let fallbackName = "Custom \(customPresets.count + 1)"
    let preset = AudioEffectChainPreset.custom(
      name: trimmedName.isEmpty ? fallbackName : trimmedName,
      nodes: effectChain
    )

    customPresets.insert(preset, at: 0)
    selectedPresetID = preset.id
    persistCustomPresets()
  }

  func deleteCustomPreset(id: String) {
    customPresets.removeAll { $0.id == id }
    if selectedPresetID == id {
      selectedPresetID = ""
    }
    persistCustomPresets()
  }

  func toggleListening() async {
    if isListening {
      stopListening()
    } else {
      await startListening()
    }
  }

  func handleInterruption(_ notification: Notification) {
    guard
      let info = notification.userInfo,
      let typeRaw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
      let type = AVAudioSession.InterruptionType(rawValue: typeRaw)
    else { return }

    switch type {
    case .began:
      let shouldResume = isListening
      if isListening {
        stopListening(restoreDiscovery: false)
      }
      shouldResumeAfterInterruption = shouldResume
    case .ended:
      let optionsRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
      let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
      let resume = options.contains(.shouldResume) && shouldResumeAfterInterruption
      shouldResumeAfterInterruption = false
      if resume {
        Task { await startListening() }
      }
    @unknown default:
      break
    }
  }

  func stopListening(restoreDiscovery: Bool = true) {
    shouldResumeAfterInterruption = false
    clockTask?.cancel()
    clockTask = nil

    if let engine {
      engine.inputNode.removeTap(onBus: 0)
      engine.stop()
      engine.reset()
    }

    engine = nil
    sourceNode = nil
    environmentNode = nil
    effectProcessor = nil
    isListening = false
    isHeadTrackedSpatialActive = false
    elapsedTime = 0
    inputChannelCount = 0

    if restoreDiscovery {
      restoreDiscoverySessionIfIdle()
    } else {
      refreshRoute()
    }
  }

  private func startListening() async {
    errorMessage = nil
    guard requireHeadphoneRouteForStart() else { return }
    guard await ensurePermission() else { return }
    guard requireHeadphoneRouteForStart() else { return }

    stopListening(restoreDiscovery: false)

    do {
      try configureListeningSession()
      guard requireHeadphoneRouteForStart() else { return }

      let engine = AVAudioEngine()
      let inputNode = engine.inputNode
      let inputFormat = inputNode.outputFormat(forBus: 0)
      guard inputFormat.channelCount > 0 else {
        throw AudioError.unavailableInputFormat
      }
      inputChannelCount = Int(inputFormat.channelCount)

      let outputChannelCount = max(Int(inputFormat.channelCount), 2)
      guard let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: inputFormat.sampleRate,
        channels: AVAudioChannelCount(outputChannelCount),
        interleaved: false
      ) else {
        throw AudioError.unavailableOutputFormat
      }

      let effectProcessor = LowLevelEffectProcessorObjC()
      effectProcessor.prepare(
        withSampleRate: outputFormat.sampleRate,
        channelCount: Int(outputFormat.channelCount),
        maximumFrameCount: selectedAudioBufferSize.maximumFrameCount
      )

      let sourceNode = AVAudioSourceNode { @Sendable _, _, frameCount, audioBufferList in
        effectProcessor.renderFrameCount(
          frameCount,
          outputAudioBufferList: audioBufferList
        )
        return noErr
      }

      let environmentNode = AVAudioEnvironmentNode()

      engine.attach(sourceNode)
      engine.attach(environmentNode)
      engine.connect(sourceNode, to: environmentNode, format: outputFormat)
      engine.connect(environmentNode, to: engine.mainMixerNode, format: outputFormat)
      configureHeadTrackedSpatialRendering(
        environmentNode: environmentNode,
        sourceNode: sourceNode
      )

      self.engine = engine
      self.sourceNode = sourceNode
      self.environmentNode = environmentNode
      self.effectProcessor = effectProcessor

      engine.mainMixerNode.outputVolume = Float(outputLevel)
      applyCurrentChain()
      installInputTap(on: inputNode, format: inputFormat, effectProcessor: effectProcessor)

      try engine.start()
      guard engine.isRunning else {
        throw AudioError.engineDidNotStart
      }

      isListening = true
      isHeadTrackedSpatialActive = true
      elapsedTime = 0
      startClock()
      refreshRoute()
    } catch {
      stopListening(restoreDiscovery: false)
      setError(error)
    }
  }

  private func ensurePermission() async -> Bool {
    if isPrepared, microphonePermissionState == .granted {
      return true
    }

    guard await requestMicrophonePermissionIfNeeded() else {
      return false
    }

    await prepare()
    return isPrepared
  }

  private func configureDiscoverySession() throws {
    try session.setCategory(
      .playAndRecord,
      mode: .measurement,
      options: [.allowBluetoothHFP, .allowBluetoothA2DP]
    )
    try session.setActive(true)
  }

  private func configureListeningSession() throws {
    try session.setCategory(
      .playAndRecord,
      mode: .measurement,
      options: [.allowBluetoothHFP, .allowBluetoothA2DP]
    )
    try? session.setPreferredSampleRate(48_000)
    try? session.setPreferredIOBufferDuration(
      selectedAudioBufferSize.preferredDuration(sampleRate: 48_000)
    )
    try session.setActive(true)
    refreshAudioInputs()
    try applyPreferredInput(id: selectedInputID)
  }

  private func applyPreferredInput(id: String) throws {
    guard let port = inputPorts.first(where: { $0.uid == id }) else { return }
    try session.setPreferredInput(port)
    applyStereoConfiguration(for: port)
  }

  private func configureHeadTrackedSpatialRendering(
    environmentNode: AVAudioEnvironmentNode,
    sourceNode: AVAudioSourceNode
  ) {
    environmentNode.outputType = .headphones
    environmentNode.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
    environmentNode.listenerAngularOrientation = AVAudio3DAngularOrientation(yaw: 0, pitch: 0, roll: 0)
    environmentNode.isListenerHeadTrackingEnabled = true

    sourceNode.sourceMode = .pointSource
    sourceNode.pointSourceInHeadMode = .mono
    sourceNode.position = AVAudio3DPoint(x: 0, y: 0, z: -1.4)
    sourceNode.reverbBlend = 0
    sourceNode.renderingAlgorithm = preferredSpatialRenderingAlgorithm(for: environmentNode)
  }

  private func preferredSpatialRenderingAlgorithm(for environmentNode: AVAudioEnvironmentNode) -> AVAudio3DMixingRenderingAlgorithm {
    let algorithms = Set(environmentNode.applicableRenderingAlgorithms.compactMap { value in
      AVAudio3DMixingRenderingAlgorithm(rawValue: value.intValue)
    })

    if algorithms.contains(.auto) {
      return .auto
    }

    if algorithms.contains(.HRTFHQ) {
      return .HRTFHQ
    }

    if algorithms.contains(.HRTF) {
      return .HRTF
    }

    return .sphericalHead
  }

  private func requireHeadphoneRouteForStart() -> Bool {
    refreshRoute()
    guard isHeadphoneOutput else {
      headphoneRouteMessage = headphoneRouteRequiredMessage
      return false
    }
    headphoneRouteMessage = nil
    return true
  }

  private func stopListeningForMissingHeadphoneRoute() {
    stopListening()
    headphoneRouteMessage = headphoneRouteLostMessage
  }

  private func synchronizeMicrophonePermission() {
    switch AVAudioApplication.shared.recordPermission {
    case .undetermined:
      if microphonePermissionState != .requesting {
        microphonePermissionState = .undetermined
      }
    case .denied:
      microphonePermissionState = .denied
    case .granted:
      microphonePermissionState = .granted
    @unknown default:
      microphonePermissionState = .denied
    }
  }

  private func requestMicrophonePermissionIfNeeded() async -> Bool {
    switch AVAudioApplication.shared.recordPermission {
    case .granted:
      microphonePermissionState = .granted
      return true
    case .denied:
      microphonePermissionState = .denied
      isPrepared = false
      refreshRoute()
      return false
    case .undetermined:
      microphonePermissionState = .requesting
      let granted = await AVAudioApplication.requestRecordPermission()
      microphonePermissionState = granted ? .granted : .denied
      if granted == false {
        isPrepared = false
        refreshRoute()
      }
      return granted
    @unknown default:
      microphonePermissionState = .denied
      isPrepared = false
      setError(AudioError.unavailableMicrophonePermission)
      refreshRoute()
      return false
    }
  }

  /// Requests a stereo capture path on the given input port. The built-in mic on
  /// recent iPhones exposes a data source whose `supportedPolarPatterns`
  /// include `.stereo`; selecting that source plus the matching polar pattern,
  /// the device orientation, and a 2-channel preference is what actually
  /// produces a 2 ch input format on the engine side. Each step is best-effort:
  /// older devices, Bluetooth, and USB inputs silently fall back to whatever
  /// they natively support, and the engine handles mono returns by mirroring L
  /// to R.
  private func applyStereoConfiguration(for port: AVAudioSessionPortDescription) {
    if port.portType == .builtInMic, let dataSources = port.dataSources {
      let stereoSource = dataSources.first { source in
        source.supportedPolarPatterns?.contains(.stereo) == true
      }
      if let stereoSource {
        try? stereoSource.setPreferredPolarPattern(.stereo)
        try? port.setPreferredDataSource(stereoSource)
      }
    }
    try? session.setPreferredInputOrientation(.portrait)
    try? session.setPreferredInputNumberOfChannels(2)
  }

  private func applyCurrentChain() {
    // Append a preview node when the user is auditioning an effect from the
    // browser. The preview is always audible (ignores Solo) so the user can
    // hear what they are picking; Bypass still cuts everything.
    let chainNodes: [AudioEffectNode]
    if let previewKind {
      chainNodes = effectChain + [AudioEffectNode(id: previewNodeID, type: previewKind)]
    } else {
      chainNodes = effectChain
    }

    let clampedIntensity = min(max(intensity, 0), 1)
    let effectTypes = chainNodes.map { NSNumber(value: $0.type.id) }
    let amounts = chainNodes.map { node in
      NSNumber(value: Float(min(max(node.amount * clampedIntensity, 0), 1)))
    }
    let parametersA = chainNodes.map { NSNumber(value: Float(min(max($0.parameterA, 0), 1))) }
    let parametersB = chainNodes.map { NSNumber(value: Float(min(max($0.parameterB, 0), 1))) }
    let parametersC = chainNodes.map { NSNumber(value: Float(min(max($0.parameterC, 0), 1))) }
    let soloed = soloedEffectIDs
    let bypassed = isBypassed
    let previewID = previewNodeID
    let isPreviewing = previewKind != nil
    let enabled = chainNodes.map { node -> NSNumber in
      let value: Bool
      if bypassed {
        value = false
      } else if isPreviewing && node.id == previewID {
        value = true
      } else if soloed.isEmpty {
        value = node.isEnabled
      } else {
        value = soloed.contains(node.id)
      }
      return NSNumber(value: value)
    }

    effectProcessor?.update(
      withEffectTypes: effectTypes,
      amounts: amounts,
      parametersA: parametersA,
      parametersB: parametersB,
      parametersC: parametersC,
      enabled: enabled
    )
    engine?.mainMixerNode.outputVolume = Float(outputLevel)
  }

  private func installInputTap(
    on inputNode: AVAudioInputNode,
    format: AVAudioFormat,
    effectProcessor: LowLevelEffectProcessorObjC
  ) {
    inputNode.installTap(onBus: 0, bufferSize: selectedAudioBufferSize.frameCount, format: format) { @Sendable buffer, _ in
      effectProcessor.writeInputBuffer(buffer)
    }
  }

  private func loadAudioBufferSize() {
    let storedFrameCount = AVAudioFrameCount(UserDefaults.standard.integer(forKey: audioBufferSizeStoreKey))
    guard let option = AudioBufferSizeOption.with(frameCount: storedFrameCount) else { return }
    selectedAudioBufferSize = option
  }

  private func persistAudioBufferSize() {
    UserDefaults.standard.set(Int(selectedAudioBufferSize.frameCount), forKey: audioBufferSizeStoreKey)
  }

  private func loadCustomPresets() {
    guard let data = UserDefaults.standard.data(forKey: customPresetStoreKey) else { return }
    customPresets = (try? JSONDecoder().decode([AudioEffectChainPreset].self, from: data)) ?? []
  }

  private func persistCustomPresets() {
    guard let data = try? JSONEncoder().encode(customPresets) else { return }
    UserDefaults.standard.set(data, forKey: customPresetStoreKey)
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

    if isHeadphoneOutput {
      headphoneRouteMessage = nil
    }
  }

  private func startClock() {
    clockTask?.cancel()

    let startedAt = Date()
    clockTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        guard let self, self.isListening else { return }
        self.elapsedTime = Date().timeIntervalSince(startedAt)
        try? await Task.sleep(for: .seconds(1))
      }
    }
  }

  private func setError(_ error: any Error) {
    errorMessage = error.localizedDescription
    isListening = false
  }

  private func restoreDiscoverySessionIfIdle() {
    guard isListening == false else { return }

    do {
      try configureDiscoverySession()
      refreshAudioInputs()
    } catch {
      refreshRoute()
    }
  }

  nonisolated private static func durationText(_ duration: TimeInterval) -> String {
    let totalSeconds = max(Int(duration.rounded()), 0)
    return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
  }
}
