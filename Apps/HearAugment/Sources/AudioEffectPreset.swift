import CoreTransferable
import Foundation
import UniformTypeIdentifiers

// MARK: - Parameter Display Format

nonisolated enum ParameterDisplayFormat: Sendable, Hashable {
  case percent
  case hertz(lower: Double, upper: Double)
  case milliseconds(lower: Double, upper: Double)
  case semitones(lower: Double, upper: Double)

  func format(value: Double) -> String {
    let clamped = min(max(value, 0), 1)
    switch self {
    case .percent:
      return "\(Int((clamped * 100).rounded()))%"
    case .hertz(let lower, let upper):
      let hz = lower + (upper - lower) * clamped
      return String(format: "%.1f Hz", hz)
    case .milliseconds(let lower, let upper):
      let ms = Int((lower + (upper - lower) * clamped).rounded())
      return "\(ms) ms"
    case .semitones(let lower, let upper):
      let st = lower + (upper - lower) * clamped
      return String(format: "%+.1f st", st)
    }
  }
}

// MARK: - Parameter Metadata

nonisolated struct ParameterMetadata: Sendable, Hashable {
  let name: String
  let defaultValue: Double
  let format: ParameterDisplayFormat

  func display(value: Double) -> String {
    format.format(value: value)
  }
}

// MARK: - Audio Effect Kind

/// Identity + metadata for one effect type. Each kind is declared as a static
/// constant. The integer `id` stays in sync with the C++ engine's `EffectType`
/// enum and is the persisted key for stored presets.
nonisolated struct AudioEffectKind: Sendable, Identifiable {
  let id: Int
  let title: String
  let subtitle: String
  let symbolName: String
  let amount: ParameterMetadata
  let parameterA: ParameterMetadata
  let parameterB: ParameterMetadata
  let parameterC: ParameterMetadata?
}

nonisolated extension AudioEffectKind: Hashable {
  static func == (lhs: AudioEffectKind, rhs: AudioEffectKind) -> Bool {
    lhs.id == rhs.id
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(id)
  }
}

nonisolated extension AudioEffectKind {
  static let allCases: [AudioEffectKind] = [
    .highPass, .lowPass, .tiltEQ, .presenceEQ, .compressor, .noiseGate,
    .softClip, .waveFolder, .bitCrusher, .tremolo, .ringMod, .panner,
    .autoPan, .vibrato, .chorus, .flanger, .phaser, .slapDelay,
    .acceleratingDelay, .pingPongDelay, .reverse, .roomReverb, .stereoReverb,
    .shimmer, .combResonator, .spaceWidener, .longBloom, .convergingBloom,
    .tapeRiserDelay, .stereoDelay, .binauralBeat,
  ]

  private static let byID: [Int: AudioEffectKind] = Dictionary(
    uniqueKeysWithValues: allCases.map { ($0.id, $0) }
  )

  static func with(id: Int) -> AudioEffectKind? {
    byID[id]
  }
}

// MARK: - Audio Effect Kind Cases

nonisolated extension AudioEffectKind {
  static let highPass = AudioEffectKind(
    id: 1,
    title: "High Pass",
    subtitle: "Low-cut cleanup",
    symbolName: "line.diagonal",
    amount: .init(name: "Amount", defaultValue: 0.55, format: .percent),
    parameterA: .init(name: "Frequency", defaultValue: 0.24, format: .percent),
    parameterB: .init(name: "Resonance", defaultValue: 0.25, format: .percent),
    parameterC: nil
  )

  static let lowPass = AudioEffectKind(
    id: 2,
    title: "Low Pass",
    subtitle: "High-cut smoothing",
    symbolName: "line.diagonal.arrow",
    amount: .init(name: "Amount", defaultValue: 0.55, format: .percent),
    parameterA: .init(name: "Frequency", defaultValue: 0.72, format: .percent),
    parameterB: .init(name: "Resonance", defaultValue: 0.25, format: .percent),
    parameterC: nil
  )

  static let tiltEQ = AudioEffectKind(
    id: 3,
    title: "Tilt EQ",
    subtitle: "Dark to bright balance",
    symbolName: "slider.horizontal.below.square.and.square.filled",
    amount: .init(name: "Amount", defaultValue: 0.55, format: .percent),
    parameterA: .init(name: "Tilt", defaultValue: 0.58, format: .percent),
    parameterB: .init(name: "Air", defaultValue: 0.48, format: .percent),
    parameterC: nil
  )

  static let presenceEQ = AudioEffectKind(
    id: 4,
    title: "Presence EQ",
    subtitle: "Speech detail lift",
    symbolName: "person.wave.2",
    amount: .init(name: "Amount", defaultValue: 0.55, format: .percent),
    parameterA: .init(name: "Focus", defaultValue: 0.58, format: .percent),
    parameterB: .init(name: "Air", defaultValue: 0.6, format: .percent),
    parameterC: nil
  )

  static let compressor = AudioEffectKind(
    id: 5,
    title: "Compressor",
    subtitle: "Fast level control",
    symbolName: "arrow.down.right.and.arrow.up.left",
    amount: .init(name: "Amount", defaultValue: 0.7, format: .percent),
    parameterA: .init(name: "Threshold", defaultValue: 0.34, format: .percent),
    parameterB: .init(name: "Ratio", defaultValue: 0.52, format: .percent),
    parameterC: nil
  )

  static let noiseGate = AudioEffectKind(
    id: 6,
    title: "Noise Gate",
    subtitle: "Quiet sound reduction",
    symbolName: "speaker.slash",
    amount: .init(name: "Amount", defaultValue: 0.35, format: .percent),
    parameterA: .init(name: "Threshold", defaultValue: 0.28, format: .percent),
    parameterB: .init(name: "Floor", defaultValue: 0.38, format: .percent),
    parameterC: nil
  )

  static let softClip = AudioEffectKind(
    id: 7,
    title: "Soft Clip",
    subtitle: "Analog-style drive",
    symbolName: "waveform.path.ecg",
    amount: .init(name: "Amount", defaultValue: 0.42, format: .percent),
    parameterA: .init(name: "Drive", defaultValue: 0.42, format: .percent),
    parameterB: .init(name: "Tone", defaultValue: 0.5, format: .percent),
    parameterC: nil
  )

  static let waveFolder = AudioEffectKind(
    id: 8,
    title: "Wave Folder",
    subtitle: "Folded harmonic edge",
    symbolName: "alternatingcurrent",
    amount: .init(name: "Amount", defaultValue: 0.42, format: .percent),
    parameterA: .init(name: "Drive", defaultValue: 0.42, format: .percent),
    parameterB: .init(name: "Tone", defaultValue: 0.5, format: .percent),
    parameterC: nil
  )

  static let bitCrusher = AudioEffectKind(
    id: 9,
    title: "Bit Crusher",
    subtitle: "Reduced resolution",
    symbolName: "square.grid.3x3",
    amount: .init(name: "Amount", defaultValue: 0.28, format: .percent),
    parameterA: .init(name: "Bits", defaultValue: 0.35, format: .percent),
    parameterB: .init(name: "Rate", defaultValue: 0.22, format: .percent),
    parameterC: nil
  )

  static let tremolo = AudioEffectKind(
    id: 10,
    title: "Tremolo",
    subtitle: "Amplitude motion",
    symbolName: "waveform",
    amount: .init(name: "Amount", defaultValue: 0.45, format: .percent),
    parameterA: .init(name: "Rate", defaultValue: 0.38, format: .percent),
    parameterB: .init(name: "Shape", defaultValue: 0.45, format: .percent),
    parameterC: nil
  )

  static let ringMod = AudioEffectKind(
    id: 11,
    title: "Ring Mod",
    subtitle: "Metallic modulation",
    symbolName: "circle.hexagongrid",
    amount: .init(name: "Amount", defaultValue: 0.45, format: .percent),
    parameterA: .init(name: "Rate", defaultValue: 0.46, format: .percent),
    parameterB: .init(name: "Blend", defaultValue: 0.55, format: .percent),
    parameterC: nil
  )

  static let panner = AudioEffectKind(
    id: 12,
    title: "Panner",
    subtitle: "Static stereo position",
    symbolName: "dot.arrowtriangles.up.right.down.left.circle",
    amount: .init(name: "Amount", defaultValue: 0.65, format: .percent),
    parameterA: .init(name: "Position", defaultValue: 0.5, format: .percent),
    parameterB: .init(name: "Gain", defaultValue: 0.72, format: .percent),
    parameterC: nil
  )

  static let autoPan = AudioEffectKind(
    id: 13,
    title: "Auto Pan",
    subtitle: "Moving stereo position",
    symbolName: "arrow.left.and.right.circle",
    amount: .init(name: "Amount", defaultValue: 0.65, format: .percent),
    parameterA: .init(name: "Rate", defaultValue: 0.32, format: .percent),
    parameterB: .init(name: "Width", defaultValue: 0.78, format: .percent),
    parameterC: nil
  )

  static let vibrato = AudioEffectKind(
    id: 14,
    title: "Vibrato",
    subtitle: "Pitch wobble",
    symbolName: "water.waves",
    amount: .init(name: "Amount", defaultValue: 0.48, format: .percent),
    parameterA: .init(name: "Rate", defaultValue: 0.25, format: .percent),
    parameterB: .init(name: "Depth", defaultValue: 0.45, format: .percent),
    parameterC: nil
  )

  static let chorus = AudioEffectKind(
    id: 15,
    title: "Chorus",
    subtitle: "Thick modulated doubles",
    symbolName: "person.2.wave.2",
    amount: .init(name: "Amount", defaultValue: 0.48, format: .percent),
    parameterA: .init(name: "Rate", defaultValue: 0.28, format: .percent),
    parameterB: .init(name: "Depth", defaultValue: 0.56, format: .percent),
    parameterC: nil
  )

  static let flanger = AudioEffectKind(
    id: 16,
    title: "Flanger",
    subtitle: "Short comb sweep",
    symbolName: "waveform.path",
    amount: .init(name: "Amount", defaultValue: 0.48, format: .percent),
    parameterA: .init(name: "Rate", defaultValue: 0.36, format: .percent),
    parameterB: .init(name: "Depth", defaultValue: 0.62, format: .percent),
    parameterC: nil
  )

  static let phaser = AudioEffectKind(
    id: 17,
    title: "Phaser",
    subtitle: "All-pass sweep",
    symbolName: "circle.dotted.circle",
    amount: .init(name: "Amount", defaultValue: 0.48, format: .percent),
    parameterA: .init(name: "Rate", defaultValue: 0.34, format: .percent),
    parameterB: .init(name: "Feedback", defaultValue: 0.54, format: .percent),
    parameterC: nil
  )

  static let slapDelay = AudioEffectKind(
    id: 18,
    title: "Slap Delay",
    subtitle: "Short feedback echo",
    symbolName: "metronome",
    amount: .init(name: "Amount", defaultValue: 0.52, format: .percent),
    parameterA: .init(name: "Time", defaultValue: 0.34, format: .milliseconds(lower: 55, upper: 520)),
    parameterB: .init(name: "Feedback", defaultValue: 0.46, format: .percent),
    parameterC: nil
  )

  static let acceleratingDelay = AudioEffectKind(
    id: 19,
    title: "Accel Delay",
    subtitle: "Repeats get faster",
    symbolName: "forward.end",
    amount: .init(name: "Amount", defaultValue: 0.52, format: .percent),
    parameterA: .init(name: "Time", defaultValue: 0.58, format: .milliseconds(lower: 160, upper: 900)),
    parameterB: .init(name: "Acceleration", defaultValue: 0.7, format: .percent),
    parameterC: nil
  )

  static let pingPongDelay = AudioEffectKind(
    id: 20,
    title: "Ping Pong",
    subtitle: "Cross-channel echoes",
    symbolName: "arrow.left.arrow.right",
    amount: .init(name: "Amount", defaultValue: 0.52, format: .percent),
    parameterA: .init(name: "Time", defaultValue: 0.44, format: .milliseconds(lower: 85, upper: 720)),
    parameterB: .init(name: "Feedback", defaultValue: 0.55, format: .percent),
    parameterC: nil
  )

  static let reverse = AudioEffectKind(
    id: 21,
    title: "Reverse",
    subtitle: "Backward grains",
    symbolName: "backward.end",
    amount: .init(name: "Amount", defaultValue: 0.62, format: .percent),
    parameterA: .init(name: "Grain", defaultValue: 0.36, format: .milliseconds(lower: 80, upper: 1050)),
    parameterB: .init(name: "Smear", defaultValue: 0.42, format: .milliseconds(lower: 12, upper: 260)),
    parameterC: nil
  )

  static let roomReverb = AudioEffectKind(
    id: 22,
    title: "Room Reverb",
    subtitle: "Compact reflection tank",
    symbolName: "smallcircle.filled.circle",
    amount: .init(name: "Amount", defaultValue: 0.44, format: .percent),
    parameterA: .init(name: "Size", defaultValue: 0.42, format: .percent),
    parameterB: .init(name: "Damping", defaultValue: 0.48, format: .percent),
    parameterC: nil
  )

  static let stereoReverb = AudioEffectKind(
    id: 23,
    title: "Stereo Reverb",
    subtitle: "Wide cross-fed tail",
    symbolName: "dot.radiowaves.left.and.right",
    amount: .init(name: "Amount", defaultValue: 0.44, format: .percent),
    parameterA: .init(name: "Size", defaultValue: 0.62, format: .percent),
    parameterB: .init(name: "Damping", defaultValue: 0.38, format: .percent),
    parameterC: nil
  )

  static let shimmer = AudioEffectKind(
    id: 24,
    title: "Shimmer",
    subtitle: "Bright diffuse bloom",
    symbolName: "sparkles",
    amount: .init(name: "Amount", defaultValue: 0.44, format: .percent),
    parameterA: .init(name: "Size", defaultValue: 0.7, format: .percent),
    parameterB: .init(name: "Damping", defaultValue: 0.32, format: .percent),
    parameterC: nil
  )

  static let combResonator = AudioEffectKind(
    id: 25,
    title: "Comb Resonator",
    subtitle: "Tuned resonant echo",
    symbolName: "tuningfork",
    amount: .init(name: "Amount", defaultValue: 0.38, format: .percent),
    parameterA: .init(name: "Tune", defaultValue: 0.46, format: .percent),
    parameterB: .init(name: "Feedback", defaultValue: 0.62, format: .percent),
    parameterC: nil
  )

  static let spaceWidener = AudioEffectKind(
    id: 26,
    title: "Space Widener",
    subtitle: "Mid-side width",
    symbolName: "arrow.up.left.and.arrow.down.right",
    amount: .init(name: "Amount", defaultValue: 0.65, format: .percent),
    parameterA: .init(name: "Width", defaultValue: 0.58, format: .percent),
    parameterB: .init(name: "Bass Mono", defaultValue: 0.45, format: .percent),
    parameterC: nil
  )

  static let longBloom = AudioEffectKind(
    id: 27,
    title: "Long Bloom",
    subtitle: "Long expanding decay",
    symbolName: "sparkles",
    amount: .init(name: "Amount", defaultValue: 0.68, format: .percent),
    parameterA: .init(name: "Size", defaultValue: 0.82, format: .percent),
    parameterB: .init(name: "Damping", defaultValue: 0.48, format: .percent),
    parameterC: nil
  )

  static let convergingBloom = AudioEffectKind(
    id: 28,
    title: "Converge Bloom",
    subtitle: "Wide tail returns center",
    symbolName: "arrow.down.forward.and.arrow.up.backward.circle",
    amount: .init(name: "Amount", defaultValue: 0.68, format: .percent),
    parameterA: .init(name: "Spread", defaultValue: 0.74, format: .percent),
    parameterB: .init(name: "Gravity", defaultValue: 0.64, format: .percent),
    parameterC: nil
  )

  static let tapeRiserDelay = AudioEffectKind(
    id: 29,
    title: "Tape Riser",
    subtitle: "Pitch-shifting tape delay",
    symbolName: "arrow.up.forward.circle",
    amount: .init(name: "Amount", defaultValue: 0.52, format: .percent),
    parameterA: .init(name: "Time", defaultValue: 0.66, format: .milliseconds(lower: 50, upper: 1000)),
    parameterB: .init(name: "Feedback", defaultValue: 0.68, format: .percent),
    parameterC: .init(name: "Pitch", defaultValue: 0.65, format: .semitones(lower: -12.0, upper: 12.0))
  )

  static let stereoDelay = AudioEffectKind(
    id: 30,
    title: "Stereo Delay",
    subtitle: "L/R offset feedback echo",
    symbolName: "rectangle.split.2x1",
    amount: .init(name: "Amount", defaultValue: 0.6, format: .percent),
    parameterA: .init(name: "Time", defaultValue: 0.42, format: .milliseconds(lower: 50, upper: 800)),
    parameterB: .init(name: "Feedback", defaultValue: 0.55, format: .percent),
    parameterC: .init(name: "Spread", defaultValue: 0.6, format: .percent)
  )

  static let binauralBeat = AudioEffectKind(
    id: 31,
    title: "Binaural Beat",
    subtitle: "Stereo carrier offset",
    symbolName: "ear.and.waveform",
    amount: .init(name: "Level", defaultValue: 0.28, format: .percent),
    parameterA: .init(name: "Carrier", defaultValue: 0.28, format: .hertz(lower: 120.0, upper: 420.0)),
    parameterB: .init(name: "Beat", defaultValue: 0.15, format: .hertz(lower: 1.0, upper: 40.0)),
    parameterC: nil
  )
}

// MARK: - Audio Effect Node

nonisolated struct AudioEffectNode: Identifiable, Hashable, Sendable {
  var id: UUID
  var type: AudioEffectKind
  var isEnabled: Bool
  var amount: Double
  var parameterA: Double
  var parameterB: Double
  var parameterC: Double

  init(
    id: UUID = UUID(),
    type: AudioEffectKind,
    isEnabled: Bool = true,
    amount: Double? = nil,
    parameterA: Double? = nil,
    parameterB: Double? = nil,
    parameterC: Double? = nil
  ) {
    self.id = id
    self.type = type
    self.isEnabled = isEnabled
    self.amount = amount ?? type.amount.defaultValue
    self.parameterA = parameterA ?? type.parameterA.defaultValue
    self.parameterB = parameterB ?? type.parameterB.defaultValue
    self.parameterC = parameterC ?? type.parameterC?.defaultValue ?? 0.5
  }
}

nonisolated extension AudioEffectNode: Codable {
  /// JSON layout is unchanged from when `type` was an `Int`-rawvalue enum: the
  /// kind id is stored under the `"type"` key. New `parameterC` field is
  /// optional so older stored presets decode cleanly.
  private enum CodingKeys: String, CodingKey {
    case id, type, isEnabled, amount, parameterA, parameterB, parameterC
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let typeID = try container.decode(Int.self, forKey: .type)
    guard let type = AudioEffectKind.with(id: typeID) else {
      throw DecodingError.dataCorruptedError(
        forKey: .type,
        in: container,
        debugDescription: "Unknown effect kind id \(typeID)"
      )
    }

    self.id = try container.decode(UUID.self, forKey: .id)
    self.type = type
    self.isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
    self.amount = try container.decode(Double.self, forKey: .amount)
    self.parameterA = try container.decode(Double.self, forKey: .parameterA)
    self.parameterB = try container.decode(Double.self, forKey: .parameterB)
    self.parameterC = try container.decodeIfPresent(Double.self, forKey: .parameterC)
      ?? type.parameterC?.defaultValue
      ?? 0.5
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(type.id, forKey: .type)
    try container.encode(isEnabled, forKey: .isEnabled)
    try container.encode(amount, forKey: .amount)
    try container.encode(parameterA, forKey: .parameterA)
    try container.encode(parameterB, forKey: .parameterB)
    try container.encode(parameterC, forKey: .parameterC)
  }
}

nonisolated extension AudioEffectNode: Transferable {
  static var transferRepresentation: some TransferRepresentation {
    CodableRepresentation(contentType: .hearAugmentEffectNode)
  }
}

nonisolated extension UTType {
  static let hearAugmentEffectNode = UTType(exportedAs: "app.muukii.hearaugment.effectNode")
}

// MARK: - Audio Effect Chain Preset

nonisolated struct AudioEffectChainPreset: Identifiable, Codable, Hashable, Sendable {
  enum Kind: String, Codable, Hashable, Sendable {
    case builtIn
    case custom
  }

  var id: String
  var name: String
  var subtitle: String
  var symbolName: String
  var accentName: String
  var kind: Kind
  var nodes: [AudioEffectNode]

  static let builtIns: [AudioEffectChainPreset] = [
    AudioEffectChainPreset(
      id: "clean",
      name: "Clean Leveler",
      subtitle: "HPF + gentle compression",
      symbolName: "waveform",
      accentName: "teal",
      kind: .builtIn,
      nodes: [
        AudioEffectNode(type: .highPass, amount: 0.38, parameterA: 0.18, parameterB: 0.2),
        AudioEffectNode(type: .compressor, amount: 0.34, parameterA: 0.22, parameterB: 0.28),
      ]
    ),
    AudioEffectChainPreset(
      id: "focus-stack",
      name: "Focus Stack",
      subtitle: "Presence, gate, fast compressor",
      symbolName: "person.wave.2",
      accentName: "blue",
      kind: .builtIn,
      nodes: [
        AudioEffectNode(type: .highPass, amount: 0.54, parameterA: 0.28, parameterB: 0.18),
        AudioEffectNode(type: .presenceEQ, amount: 0.66, parameterA: 0.68, parameterB: 0.58),
        AudioEffectNode(type: .noiseGate, amount: 0.22, parameterA: 0.24, parameterB: 0.36),
        AudioEffectNode(type: .compressor, amount: 0.78, parameterA: 0.32, parameterB: 0.62),
      ]
    ),
    AudioEffectChainPreset(
      id: "wide-room",
      name: "Wide Room",
      subtitle: "Stereo image + reverb tail",
      symbolName: "dot.radiowaves.left.and.right",
      accentName: "green",
      kind: .builtIn,
      nodes: [
        AudioEffectNode(type: .spaceWidener, amount: 0.58, parameterA: 0.62, parameterB: 0.52),
        AudioEffectNode(type: .stereoReverb, amount: 0.5, parameterA: 0.54, parameterB: 0.44),
        AudioEffectNode(type: .compressor, amount: 0.42, parameterA: 0.36, parameterB: 0.34),
      ]
    ),
    AudioEffectChainPreset(
      id: "accelerator",
      name: "Tape Accelerator",
      subtitle: "Repeats tighten and rise",
      symbolName: "forward.end",
      accentName: "pink",
      kind: .builtIn,
      nodes: [
        AudioEffectNode(type: .compressor, amount: 0.46, parameterA: 0.38, parameterB: 0.42),
        AudioEffectNode(type: .acceleratingDelay, amount: 0.64, parameterA: 0.6, parameterB: 0.76),
        AudioEffectNode(type: .tapeRiserDelay, amount: 0.58, parameterA: 0.62, parameterB: 0.7),
        AudioEffectNode(type: .softClip, amount: 0.24, parameterA: 0.32, parameterB: 0.46),
      ]
    ),
    AudioEffectChainPreset(
      id: "reverse-bloom",
      name: "Reverse Bloom",
      subtitle: "Backward grains into shimmer",
      symbolName: "backward.end",
      accentName: "purple",
      kind: .builtIn,
      nodes: [
        AudioEffectNode(type: .reverse, amount: 0.58, parameterA: 0.42, parameterB: 0.5),
        AudioEffectNode(type: .shimmer, amount: 0.46, parameterA: 0.7, parameterB: 0.3),
        AudioEffectNode(type: .spaceWidener, amount: 0.42, parameterA: 0.68, parameterB: 0.48),
      ]
    ),
    AudioEffectChainPreset(
      id: "mod-lab",
      name: "Mod Lab",
      subtitle: "Chorus, flanger, phaser",
      symbolName: "circle.hexagongrid",
      accentName: "cyan",
      kind: .builtIn,
      nodes: [
        AudioEffectNode(type: .chorus, amount: 0.46, parameterA: 0.24, parameterB: 0.58),
        AudioEffectNode(type: .flanger, amount: 0.34, parameterA: 0.4, parameterB: 0.54),
        AudioEffectNode(type: .phaser, amount: 0.48, parameterA: 0.36, parameterB: 0.58),
      ]
    ),
    AudioEffectChainPreset(
      id: "lofi-tunnel",
      name: "Lo-Fi Tunnel",
      subtitle: "Crush, filter, room",
      symbolName: "square.grid.3x3",
      accentName: "orange",
      kind: .builtIn,
      nodes: [
        AudioEffectNode(type: .bitCrusher, amount: 0.36, parameterA: 0.46, parameterB: 0.28),
        AudioEffectNode(type: .lowPass, amount: 0.58, parameterA: 0.44, parameterB: 0.24),
        AudioEffectNode(type: .roomReverb, amount: 0.38, parameterA: 0.38, parameterB: 0.58),
      ]
    ),
    AudioEffectChainPreset(
      id: "motion-field",
      name: "Motion Field",
      subtitle: "Auto pan, tremolo, ping pong",
      symbolName: "arrow.left.and.right.circle",
      accentName: "indigo",
      kind: .builtIn,
      nodes: [
        AudioEffectNode(type: .autoPan, amount: 0.56, parameterA: 0.28, parameterB: 0.74),
        AudioEffectNode(type: .tremolo, amount: 0.28, parameterA: 0.34, parameterB: 0.4),
        AudioEffectNode(type: .pingPongDelay, amount: 0.38, parameterA: 0.38, parameterB: 0.4),
      ]
    ),
    AudioEffectChainPreset(
      id: "divergence-bloom",
      name: "Divergence Bloom",
      subtitle: "Tail opens wide, then settles",
      symbolName: "sparkles",
      accentName: "purple",
      kind: .builtIn,
      nodes: [
        AudioEffectNode(type: .highPass, amount: 0.36, parameterA: 0.2, parameterB: 0.16),
        AudioEffectNode(type: .convergingBloom, amount: 0.78, parameterA: 0.86, parameterB: 0.62),
        AudioEffectNode(type: .longBloom, amount: 0.54, parameterA: 0.9, parameterB: 0.42),
        AudioEffectNode(type: .spaceWidener, amount: 0.38, parameterA: 0.7, parameterB: 0.38),
        AudioEffectNode(type: .compressor, amount: 0.28, parameterA: 0.3, parameterB: 0.32),
      ]
    ),
    AudioEffectChainPreset(
      id: "gravity-tail",
      name: "Gravity Tail",
      subtitle: "Reverse smear into long collapse",
      symbolName: "arrow.down.forward.and.arrow.up.backward.circle",
      accentName: "mint",
      kind: .builtIn,
      nodes: [
        AudioEffectNode(type: .reverse, amount: 0.36, parameterA: 0.24, parameterB: 0.58),
        AudioEffectNode(type: .convergingBloom, amount: 0.7, parameterA: 0.64, parameterB: 0.82),
        AudioEffectNode(type: .longBloom, amount: 0.62, parameterA: 0.96, parameterB: 0.68),
        AudioEffectNode(type: .lowPass, amount: 0.42, parameterA: 0.56, parameterB: 0.16),
      ]
    ),
    AudioEffectChainPreset(
      id: "tape-riser",
      name: "Tape Riser",
      subtitle: "Echoes speed up into pitch",
      symbolName: "arrow.up.forward.circle",
      accentName: "orange",
      kind: .builtIn,
      nodes: [
        AudioEffectNode(type: .highPass, amount: 0.32, parameterA: 0.22, parameterB: 0.18),
        AudioEffectNode(type: .tapeRiserDelay, amount: 0.78, parameterA: 0.72, parameterB: 0.86),
        AudioEffectNode(type: .convergingBloom, amount: 0.34, parameterA: 0.56, parameterB: 0.76),
        AudioEffectNode(type: .softClip, amount: 0.22, parameterA: 0.28, parameterB: 0.46),
      ]
    ),
  ]

  static func custom(name: String, nodes: [AudioEffectNode]) -> AudioEffectChainPreset {
    AudioEffectChainPreset(
      id: "custom-\(UUID().uuidString)",
      name: name,
      subtitle: "\(nodes.count) effects",
      symbolName: "slider.horizontal.3",
      accentName: "mint",
      kind: .custom,
      nodes: nodes
    )
  }
}
