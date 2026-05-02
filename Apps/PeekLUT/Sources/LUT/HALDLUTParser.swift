import CoreGraphics
import Foundation
import ImageIO
import UIKit

enum HALDLUTParseError: Error, Sendable {
  case unreadable
  case nonSquare(width: Int, height: Int)
  case unsupportedDimension(side: Int)
  case bitmapAllocFailed
}

enum HALDLUTParser {

  static func parse(
    data: Data,
    name: String,
    id: String,
    source: LUT.Source
  ) throws -> LUT {
    guard let image = UIImage(data: data)?.cgImage else {
      throw HALDLUTParseError.unreadable
    }
    return try parse(cgImage: image, name: name, id: id, source: source)
  }

  static func parse(
    cgImage: CGImage,
    name: String,
    id: String,
    source: LUT.Source
  ) throws -> LUT {
    let width = cgImage.width
    let height = cgImage.height
    guard width == height, width > 0 else {
      throw HALDLUTParseError.nonSquare(width: width, height: height)
    }
    let side = width

    let level = haldLevel(forSide: side)
    guard let level else {
      throw HALDLUTParseError.unsupportedDimension(side: side)
    }
    let n = level * level

    let bytesPerRow = side * 4
    var pixels = [UInt8](repeating: 0, count: side * bytesPerRow)
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    let bitmapInfo: UInt32 = CGImageAlphaInfo.premultipliedLast.rawValue
      | CGBitmapInfo.byteOrder32Big.rawValue

    guard
      let context = pixels.withUnsafeMutableBytes({ buffer -> CGContext? in
        guard let base = buffer.baseAddress else { return nil }
        return CGContext(
          data: base,
          width: side,
          height: side,
          bitsPerComponent: 8,
          bytesPerRow: bytesPerRow,
          space: colorSpace,
          bitmapInfo: bitmapInfo
        )
      })
    else {
      throw HALDLUTParseError.bitmapAllocFailed
    }
    context.draw(
      cgImage,
      in: CGRect(x: 0, y: 0, width: side, height: side)
    )

    var floats = [Float]()
    floats.reserveCapacity(n * n * n * 4)
    let inv: Float = 1.0 / 255.0

    for b in 0..<n {
      let tileX = b % level
      let tileY = b / level
      for g in 0..<n {
        let py = tileY * n + g
        let rowStart = py * bytesPerRow
        for r in 0..<n {
          let px = tileX * n + r
          let i = rowStart + px * 4
          floats.append(Float(pixels[i]) * inv)
          floats.append(Float(pixels[i + 1]) * inv)
          floats.append(Float(pixels[i + 2]) * inv)
          floats.append(1)
        }
      }
    }

    let cubeData = floats.withUnsafeBufferPointer { Data(buffer: $0) }
    return LUT(id: id, name: name, source: source, dimension: n, cubeData: cubeData)
  }

  /// Recover the HALD level L (cube edge N = L*L, image side = L*L*L = N*L) from image side.
  /// Tries integer cube root, since side == L^3 in canonical HALD layout.
  static func haldLevel(forSide side: Int) -> Int? {
    guard side > 0 else { return nil }
    let approx = Int(round(pow(Double(side), 1.0 / 3.0)))
    for candidate in [approx - 1, approx, approx + 1] where candidate > 1 {
      if candidate * candidate * candidate == side {
        return candidate
      }
    }
    return nil
  }
}
