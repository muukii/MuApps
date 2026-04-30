import Foundation

nonisolated enum AudioEffectType: Int, CaseIterable, Identifiable, Codable, Hashable, Sendable {
  case highPass = 1
  case lowPass
  case tiltEQ
  case presenceEQ
  case compressor
  case noiseGate
  case softClip
  case waveFolder
  case bitCrusher
  case tremolo
  case ringMod
  case panner
  case autoPan
  case vibrato
  case chorus
  case flanger
  case phaser
  case slapDelay
  case acceleratingDelay
  case pingPongDelay
  case reverse
  case roomReverb
  case stereoReverb
  case shimmer
  case combResonator
  case spaceWidener
  case longBloom
  case convergingBloom
  case tapeRiserDelay

  var id: Int {
    rawValue
  }

  var title: String {
    switch self {
    case .highPass:
      return "High Pass"
    case .lowPass:
      return "Low Pass"
    case .tiltEQ:
      return "Tilt EQ"
    case .presenceEQ:
      return "Presence EQ"
    case .compressor:
      return "Compressor"
    case .noiseGate:
      return "Noise Gate"
    case .softClip:
      return "Soft Clip"
    case .waveFolder:
      return "Wave Folder"
    case .bitCrusher:
      return "Bit Crusher"
    case .tremolo:
      return "Tremolo"
    case .ringMod:
      return "Ring Mod"
    case .panner:
      return "Panner"
    case .autoPan:
      return "Auto Pan"
    case .vibrato:
      return "Vibrato"
    case .chorus:
      return "Chorus"
    case .flanger:
      return "Flanger"
    case .phaser:
      return "Phaser"
    case .slapDelay:
      return "Slap Delay"
    case .acceleratingDelay:
      return "Accel Delay"
    case .tapeRiserDelay:
      return "Tape Riser"
    case .pingPongDelay:
      return "Ping Pong"
    case .reverse:
      return "Reverse"
    case .roomReverb:
      return "Room Reverb"
    case .stereoReverb:
      return "Stereo Reverb"
    case .shimmer:
      return "Shimmer"
    case .combResonator:
      return "Comb Resonator"
    case .spaceWidener:
      return "Space Widener"
    case .longBloom:
      return "Long Bloom"
    case .convergingBloom:
      return "Converge Bloom"
    }
  }

  var subtitle: String {
    switch self {
    case .highPass:
      return "Low-cut cleanup"
    case .lowPass:
      return "High-cut smoothing"
    case .tiltEQ:
      return "Dark to bright balance"
    case .presenceEQ:
      return "Speech detail lift"
    case .compressor:
      return "Fast level control"
    case .noiseGate:
      return "Quiet sound reduction"
    case .softClip:
      return "Analog-style drive"
    case .waveFolder:
      return "Folded harmonic edge"
    case .bitCrusher:
      return "Reduced resolution"
    case .tremolo:
      return "Amplitude motion"
    case .ringMod:
      return "Metallic modulation"
    case .panner:
      return "Static stereo position"
    case .autoPan:
      return "Moving stereo position"
    case .vibrato:
      return "Pitch wobble"
    case .chorus:
      return "Thick modulated doubles"
    case .flanger:
      return "Short comb sweep"
    case .phaser:
      return "All-pass sweep"
    case .slapDelay:
      return "Short feedback echo"
    case .acceleratingDelay:
      return "Repeats get faster"
    case .tapeRiserDelay:
      return "Pitch-rising tape delay"
    case .pingPongDelay:
      return "Cross-channel echoes"
    case .reverse:
      return "Backward grains"
    case .roomReverb:
      return "Compact reflection tank"
    case .stereoReverb:
      return "Wide cross-fed tail"
    case .shimmer:
      return "Bright diffuse bloom"
    case .combResonator:
      return "Tuned resonant echo"
    case .spaceWidener:
      return "Mid-side width"
    case .longBloom:
      return "Long expanding decay"
    case .convergingBloom:
      return "Wide tail returns center"
    }
  }

  var symbolName: String {
    switch self {
    case .highPass:
      return "line.diagonal"
    case .lowPass:
      return "line.diagonal.arrow"
    case .tiltEQ:
      return "slider.horizontal.below.square.and.square.filled"
    case .presenceEQ:
      return "person.wave.2"
    case .compressor:
      return "arrow.down.right.and.arrow.up.left"
    case .noiseGate:
      return "speaker.slash"
    case .softClip:
      return "waveform.path.ecg"
    case .waveFolder:
      return "alternatingcurrent"
    case .bitCrusher:
      return "square.grid.3x3"
    case .tremolo:
      return "waveform"
    case .ringMod:
      return "circle.hexagongrid"
    case .panner:
      return "dot.arrowtriangles.up.right.down.left.circle"
    case .autoPan:
      return "arrow.left.and.right.circle"
    case .vibrato:
      return "water.waves"
    case .chorus:
      return "person.2.wave.2"
    case .flanger:
      return "waveform.path"
    case .phaser:
      return "circle.dotted.circle"
    case .slapDelay:
      return "metronome"
    case .acceleratingDelay:
      return "forward.end"
    case .tapeRiserDelay:
      return "arrow.up.forward.circle"
    case .pingPongDelay:
      return "arrow.left.arrow.right"
    case .reverse:
      return "backward.end"
    case .roomReverb:
      return "smallcircle.filled.circle"
    case .stereoReverb:
      return "dot.radiowaves.left.and.right"
    case .shimmer:
      return "sparkles"
    case .combResonator:
      return "tuningfork"
    case .spaceWidener:
      return "arrow.up.left.and.arrow.down.right"
    case .longBloom:
      return "sparkles"
    case .convergingBloom:
      return "arrow.down.forward.and.arrow.up.backward.circle"
    }
  }

  var parameterAName: String {
    switch self {
    case .highPass, .lowPass:
      return "Frequency"
    case .tiltEQ:
      return "Tilt"
    case .presenceEQ:
      return "Focus"
    case .compressor, .noiseGate:
      return "Threshold"
    case .softClip, .waveFolder:
      return "Drive"
    case .bitCrusher:
      return "Bits"
    case .tremolo, .ringMod, .autoPan, .vibrato, .chorus, .flanger, .phaser:
      return "Rate"
    case .panner:
      return "Position"
    case .slapDelay, .acceleratingDelay, .tapeRiserDelay, .pingPongDelay:
      return "Time"
    case .reverse:
      return "Grain"
    case .roomReverb, .stereoReverb, .shimmer, .longBloom:
      return "Size"
    case .combResonator:
      return "Tune"
    case .spaceWidener:
      return "Width"
    case .convergingBloom:
      return "Spread"
    }
  }

  var parameterBName: String {
    switch self {
    case .highPass, .lowPass:
      return "Resonance"
    case .tiltEQ, .presenceEQ:
      return "Air"
    case .compressor:
      return "Ratio"
    case .noiseGate:
      return "Floor"
    case .softClip, .waveFolder:
      return "Tone"
    case .bitCrusher:
      return "Rate"
    case .tremolo:
      return "Shape"
    case .ringMod:
      return "Blend"
    case .panner:
      return "Gain"
    case .autoPan:
      return "Width"
    case .vibrato, .chorus, .flanger:
      return "Depth"
    case .phaser:
      return "Feedback"
    case .slapDelay, .pingPongDelay:
      return "Feedback"
    case .acceleratingDelay:
      return "Acceleration"
    case .tapeRiserDelay:
      return "Rise"
    case .reverse:
      return "Smear"
    case .roomReverb, .stereoReverb, .shimmer, .longBloom:
      return "Damping"
    case .combResonator:
      return "Feedback"
    case .spaceWidener:
      return "Bass Mono"
    case .convergingBloom:
      return "Gravity"
    }
  }

  var defaultAmount: Double {
    switch self {
    case .highPass, .lowPass, .tiltEQ, .presenceEQ:
      return 0.55
    case .compressor:
      return 0.7
    case .noiseGate:
      return 0.35
    case .softClip, .waveFolder:
      return 0.42
    case .bitCrusher:
      return 0.28
    case .tremolo, .ringMod:
      return 0.45
    case .panner, .autoPan, .spaceWidener:
      return 0.65
    case .longBloom, .convergingBloom:
      return 0.68
    case .vibrato, .chorus, .flanger, .phaser:
      return 0.48
    case .slapDelay, .acceleratingDelay, .tapeRiserDelay, .pingPongDelay:
      return 0.52
    case .reverse:
      return 0.62
    case .roomReverb, .stereoReverb, .shimmer:
      return 0.44
    case .combResonator:
      return 0.38
    }
  }

  var defaultParameterA: Double {
    switch self {
    case .highPass:
      return 0.24
    case .lowPass:
      return 0.72
    case .tiltEQ, .presenceEQ:
      return 0.58
    case .compressor:
      return 0.34
    case .noiseGate:
      return 0.28
    case .softClip, .waveFolder:
      return 0.42
    case .bitCrusher:
      return 0.35
    case .tremolo:
      return 0.38
    case .ringMod:
      return 0.46
    case .panner:
      return 0.5
    case .autoPan:
      return 0.32
    case .vibrato:
      return 0.25
    case .chorus:
      return 0.28
    case .flanger:
      return 0.36
    case .phaser:
      return 0.34
    case .slapDelay:
      return 0.34
    case .acceleratingDelay:
      return 0.58
    case .tapeRiserDelay:
      return 0.66
    case .pingPongDelay:
      return 0.44
    case .reverse:
      return 0.36
    case .roomReverb:
      return 0.42
    case .stereoReverb:
      return 0.62
    case .shimmer:
      return 0.7
    case .combResonator:
      return 0.46
    case .spaceWidener:
      return 0.58
    case .longBloom:
      return 0.82
    case .convergingBloom:
      return 0.74
    }
  }

  var defaultParameterB: Double {
    switch self {
    case .highPass, .lowPass:
      return 0.25
    case .tiltEQ:
      return 0.48
    case .presenceEQ:
      return 0.6
    case .compressor:
      return 0.52
    case .noiseGate:
      return 0.38
    case .softClip, .waveFolder:
      return 0.5
    case .bitCrusher:
      return 0.22
    case .tremolo:
      return 0.45
    case .ringMod:
      return 0.55
    case .panner:
      return 0.72
    case .autoPan:
      return 0.78
    case .vibrato:
      return 0.45
    case .chorus:
      return 0.56
    case .flanger:
      return 0.62
    case .phaser:
      return 0.54
    case .slapDelay:
      return 0.46
    case .acceleratingDelay:
      return 0.7
    case .tapeRiserDelay:
      return 0.68
    case .pingPongDelay:
      return 0.55
    case .reverse:
      return 0.42
    case .roomReverb:
      return 0.48
    case .stereoReverb:
      return 0.38
    case .shimmer:
      return 0.32
    case .combResonator:
      return 0.62
    case .spaceWidener:
      return 0.45
    case .longBloom:
      return 0.48
    case .convergingBloom:
      return 0.64
    }
  }
}

nonisolated struct AudioEffectNode: Identifiable, Codable, Hashable, Sendable {
  var id: UUID
  var type: AudioEffectType
  var isEnabled: Bool
  var amount: Double
  var parameterA: Double
  var parameterB: Double

  init(
    id: UUID = UUID(),
    type: AudioEffectType,
    isEnabled: Bool = true,
    amount: Double? = nil,
    parameterA: Double? = nil,
    parameterB: Double? = nil
  ) {
    self.id = id
    self.type = type
    self.isEnabled = isEnabled
    self.amount = amount ?? type.defaultAmount
    self.parameterA = parameterA ?? type.defaultParameterA
    self.parameterB = parameterB ?? type.defaultParameterB
  }
}

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
