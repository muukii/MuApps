import Foundation
import Observation
@preconcurrency import AVFoundation

extension LowLevelEffectProcessorObjC: @unchecked Sendable {}

@Observable
@MainActor
final class HearAugmentViewModel {
  private enum AudioError: LocalizedError {
    case unavailableInputFormat
    case unavailableOutputFormat
    case engineDidNotStart

    var errorDescription: String? {
      switch self {
      case .unavailableInputFormat:
        return "Microphone input is not available on this device."
      case .unavailableOutputFormat:
        return "The stereo listening format could not be created."
      case .engineDidNotStart:
        return "The listening engine could not be started."
      }
    }
  }

  private static let defaultPreset = AudioEffectChainPreset.builtIns[1]
  private let customPresetStoreKey = "HearAugment.CustomEffectChainPresets"
  private let audioBufferSizeStoreKey = "HearAugment.AudioBufferSize"
  private let maximumChainLength = 16
  private let session = AVAudioSession.sharedInstance()
  private var inputPorts: [AVAudioSessionPortDescription] = []
  private var engine: AVAudioEngine?
  private var sourceNode: AVAudioSourceNode?
  private var effectProcessor: LowLevelEffectProcessorObjC?
  private var clockTask: Task<Void, Never>?
  private var isApplyingPreset = false

  private(set) var inputDevices: [AudioInputDevice] = []
  private(set) var customPresets: [AudioEffectChainPreset] = []
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

  private(set) var isPrepared = false
  private(set) var isPermissionDenied = false
  private(set) var isListening = false
  private(set) var elapsedTime: TimeInterval = 0
  private(set) var outputRouteName = "System Output"
  private(set) var activeInputName = "No Input"
  private(set) var isHeadphoneOutput = false
  private(set) var errorMessage: String?

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

  func refreshAudioRoute() {
    refreshAudioInputs()
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
    effectChain = preset.nodes
    isApplyingPreset = false
  }

  func addEffect(_ type: AudioEffectType) {
    guard canAddEffect else { return }
    effectChain.append(AudioEffectNode(type: type))
  }

  func replaceEffect(_ node: AudioEffectNode) {
    guard let index = effectChain.firstIndex(where: { $0.id == node.id }) else { return }
    effectChain[index] = node
  }

  func removeEffect(id: UUID) {
    effectChain.removeAll { $0.id == id }
  }

  func moveEffect(id: UUID, offset: Int) {
    guard
      let sourceIndex = effectChain.firstIndex(where: { $0.id == id })
    else { return }

    let destinationIndex = sourceIndex + offset
    guard effectChain.indices.contains(destinationIndex) else { return }
    effectChain.swapAt(sourceIndex, destinationIndex)
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

  func stopListening(restoreDiscovery: Bool = true) {
    clockTask?.cancel()
    clockTask = nil

    if let engine {
      engine.inputNode.removeTap(onBus: 0)
      engine.stop()
      engine.reset()
    }

    engine = nil
    sourceNode = nil
    effectProcessor = nil
    isListening = false
    elapsedTime = 0

    if restoreDiscovery {
      restoreDiscoverySessionIfIdle()
    } else {
      refreshRoute()
    }
  }

  private func startListening() async {
    guard await ensurePermission() else { return }

    stopListening(restoreDiscovery: false)
    errorMessage = nil

    do {
      try configureListeningSession()

      let engine = AVAudioEngine()
      let inputNode = engine.inputNode
      let inputFormat = inputNode.outputFormat(forBus: 0)
      guard inputFormat.channelCount > 0 else {
        throw AudioError.unavailableInputFormat
      }

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

      engine.attach(sourceNode)
      engine.connect(sourceNode, to: engine.mainMixerNode, format: outputFormat)

      self.engine = engine
      self.sourceNode = sourceNode
      self.effectProcessor = effectProcessor

      engine.mainMixerNode.outputVolume = Float(outputLevel)
      applyCurrentChain()
      installInputTap(on: inputNode, format: inputFormat, effectProcessor: effectProcessor)

      try engine.start()
      guard engine.isRunning else {
        throw AudioError.engineDidNotStart
      }

      isListening = true
      elapsedTime = 0
      startClock()
      refreshRoute()
    } catch {
      stopListening(restoreDiscovery: false)
      setError(error)
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
  }

  private func applyCurrentChain() {
    let clampedIntensity = min(max(intensity, 0), 1)
    let effectTypes = effectChain.map { NSNumber(value: $0.type.rawValue) }
    let amounts = effectChain.map { node in
      NSNumber(value: Float(min(max(node.amount * clampedIntensity, 0), 1)))
    }
    let parametersA = effectChain.map { NSNumber(value: Float(min(max($0.parameterA, 0), 1))) }
    let parametersB = effectChain.map { NSNumber(value: Float(min(max($0.parameterB, 0), 1))) }
    let enabled = effectChain.map { NSNumber(value: $0.isEnabled) }

    effectProcessor?.update(
      withEffectTypes: effectTypes,
      amounts: amounts,
      parametersA: parametersA,
      parametersB: parametersB,
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
    let rawValue = UserDefaults.standard.integer(forKey: audioBufferSizeStoreKey)
    guard let option = AudioBufferSizeOption(rawValue: rawValue) else { return }
    selectedAudioBufferSize = option
  }

  private func persistAudioBufferSize() {
    UserDefaults.standard.set(selectedAudioBufferSize.rawValue, forKey: audioBufferSizeStoreKey)
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
