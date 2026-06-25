import CoreImage
import SwiftUI
import UIKit

@MainActor
final class LUTThumbnailCache: ObservableObject {

  @Published private(set) var thumbnails: [LUT.ID: UIImage] = [:]

  private let swatch: CIImage = {
    let size = CGSize(width: 96, height: 96)
    let renderer = UIGraphicsImageRenderer(size: size)
    let img = renderer.image { ctx in
      let colors = [
        UIColor.systemPink.cgColor,
        UIColor.systemOrange.cgColor,
        UIColor.systemTeal.cgColor,
        UIColor.systemPurple.cgColor,
      ] as CFArray
      let cs = CGColorSpaceCreateDeviceRGB()
      if let gradient = CGGradient(
        colorsSpace: cs,
        colors: colors,
        locations: [0, 0.4, 0.7, 1]
      ) {
        ctx.cgContext.drawLinearGradient(
          gradient,
          start: .zero,
          end: CGPoint(x: size.width, y: size.height),
          options: []
        )
      }
    }
    if let cg = img.cgImage {
      return CIImage(cgImage: cg)
    }
    return CIImage(color: .gray).cropped(to: CGRect(origin: .zero, size: size))
  }()

  func thumbnail(for id: LUT.ID) -> UIImage? {
    thumbnails[id]
  }

  /// Regenerate any missing thumbnails for the given LUTs. Cheap; safe to call on view appear.
  func ensureThumbnails(for luts: [LUT]) {
    var updated = thumbnails
    var didChange = false
    for lut in luts where updated[lut.id] == nil {
      let processed = LUTRenderer.shared.apply(lut: lut, to: swatch)
      if let ui = LUTRenderer.shared.renderUIImage(processed, maxPixel: 96) {
        updated[lut.id] = ui
        didChange = true
      }
    }
    if didChange {
      thumbnails = updated
    }
  }
}
