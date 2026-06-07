import SwiftUI
import UIKit

/// A bundled Codex Desktop pet that can be rendered from a fixed sprite atlas.
struct CodexPet: Hashable, Identifiable {
  /// Stable identifier matching the Codex custom pet package name.
  let id: String

  /// User-facing name shown in the pet picker.
  let displayName: String

  /// Compact label used by segmented controls on narrow screens.
  let pickerTitle: String

  /// Short description of the pet source and style.
  let description: String

  /// Name of the asset catalog image that stores the complete sprite atlas.
  let spriteSheetAssetName: String

  /// Rendering mode used when magnifying the sprite.
  let renderingStyle: CodexPetRenderingStyle

  static let builtInPets: [CodexPet] = [
    CodexPet(
      id: "mofu-monkey",
      displayName: "Mofu Monkey",
      pickerTitle: "Mofu",
      description: "Soft plush Codex pet",
      spriteSheetAssetName: "MofuMonkeySpritesheet",
      renderingStyle: .soft
    ),
    CodexPet(
      id: "mofu-monkey-dot",
      displayName: "Mofu Monkey Dot",
      pickerTitle: "Dot",
      description: "Pixel-art Codex pet",
      spriteSheetAssetName: "MofuMonkeyDotSpritesheet",
      renderingStyle: .pixel
    ),
  ]
}

/// Rendering preference for a pet atlas when it is scaled on screen.
enum CodexPetRenderingStyle {
  /// Smooth interpolation for illustration-like sprites.
  case soft

  /// Nearest-neighbor interpolation for pixel art sprites.
  case pixel

  var interpolation: Image.Interpolation {
    switch self {
    case .soft:
      .high
    case .pixel:
      .none
    }
  }
}

/// The animation rows defined by the Codex custom pet atlas contract.
enum CodexPetAnimation: String, CaseIterable, Hashable, Identifiable {
  case idle
  case runningRight = "running-right"
  case runningLeft = "running-left"
  case waving
  case jumping
  case failed
  case waiting
  case running
  case review

  var id: String { rawValue }

  /// Zero-based row in the 8 x 9 sprite atlas.
  var rowIndex: Int {
    switch self {
    case .idle:
      0
    case .runningRight:
      1
    case .runningLeft:
      2
    case .waving:
      3
    case .jumping:
      4
    case .failed:
      5
    case .waiting:
      6
    case .running:
      7
    case .review:
      8
    }
  }

  var title: String {
    switch self {
    case .idle:
      "Idle"
    case .runningRight:
      "Right"
    case .runningLeft:
      "Left"
    case .waving:
      "Wave"
    case .jumping:
      "Jump"
    case .failed:
      "Failed"
    case .waiting:
      "Wait"
    case .running:
      "Work"
    case .review:
      "Review"
    }
  }

  var systemImageName: String {
    switch self {
    case .idle:
      "moon.zzz.fill"
    case .runningRight:
      "arrow.right"
    case .runningLeft:
      "arrow.left"
    case .waving:
      "hand.wave.fill"
    case .jumping:
      "arrow.up"
    case .failed:
      "exclamationmark.triangle.fill"
    case .waiting:
      "hourglass"
    case .running:
      "gearshape.2.fill"
    case .review:
      "eye.fill"
    }
  }

  var framesPerSecond: Double {
    switch self {
    case .idle, .review:
      6
    case .waiting:
      7
    case .running, .runningLeft, .runningRight:
      12
    case .jumping, .waving:
      10
    case .failed:
      8
    }
  }

  /// A representative frame for surfaces that render a snapshot instead of live animation.
  var staticFrameIndex: Int {
    switch self {
    case .idle:
      0
    case .runningRight, .runningLeft:
      2
    case .waving:
      1
    case .jumping:
      2
    case .failed:
      3
    case .waiting:
      2
    case .running:
      4
    case .review:
      3
    }
  }
}

/// A decoded sprite atlas split into frame images for fast SwiftUI playback.
struct CodexPetSpriteSheet {
  /// Fixed pixel geometry used by Codex Desktop custom pet atlases.
  struct Geometry {
    let columns: Int
    let rows: Int
    let cellWidth: Int
    let cellHeight: Int

    static let codexPet = Geometry(
      columns: 8,
      rows: 9,
      cellWidth: 192,
      cellHeight: 208
    )
  }

  let pet: CodexPet
  let geometry: Geometry

  private let framesByAnimation: [CodexPetAnimation: [UIImage]]

  init?(pet: CodexPet, geometry: Geometry = .codexPet) {
    guard let atlas = UIImage(named: pet.spriteSheetAssetName)?.cgImage else {
      return nil
    }

    self.pet = pet
    self.geometry = geometry

    var framesByAnimation: [CodexPetAnimation: [UIImage]] = [:]

    for animation in CodexPetAnimation.allCases {
      let frames = (0..<geometry.columns).compactMap { column -> UIImage? in
        let cropRect = CGRect(
          x: column * geometry.cellWidth,
          y: animation.rowIndex * geometry.cellHeight,
          width: geometry.cellWidth,
          height: geometry.cellHeight
        )

        guard let frame = atlas.cropping(to: cropRect) else {
          return nil
        }

        guard Self.hasVisiblePixels(in: frame) else {
          return nil
        }

        // Keep the full cell crop so the pet's atlas registration stays intact.
        return UIImage(cgImage: frame, scale: 1, orientation: .up)
      }

      framesByAnimation[animation] = frames
    }

    self.framesByAnimation = framesByAnimation
  }

  func frame(for animation: CodexPetAnimation, at index: Int) -> UIImage? {
    guard let frames = framesByAnimation[animation], frames.isEmpty == false else {
      return nil
    }

    return frames[index % frames.count]
  }

  private static func hasVisiblePixels(in image: CGImage) -> Bool {
    let width = image.width
    let height = image.height
    let bytesPerPixel = 4
    let bytesPerRow = width * bytesPerPixel
    var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)

    guard let context = CGContext(
      data: &pixels,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: bytesPerRow,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
      return true
    }

    context.draw(
      image,
      in: CGRect(x: 0, y: 0, width: width, height: height)
    )

    return stride(from: 3, to: pixels.count, by: bytesPerPixel).contains { index in
      pixels[index] > 4
    }
  }
}

enum CodexPetPalette {
  static let background = Color(red: 0.97, green: 0.98, blue: 0.97)
  static let stage = Color(red: 0.91, green: 0.96, blue: 0.95)
  static let ground = Color(red: 0.22, green: 0.45, blue: 0.35)
  static let accent = Color(red: 0.02, green: 0.48, blue: 0.58)
  static let control = Color(red: 0.96, green: 0.93, blue: 0.87)
  static let controlText = Color(red: 0.18, green: 0.22, blue: 0.24)
  static let secondaryText = Color(red: 0.42, green: 0.48, blue: 0.5)
}
