import Foundation

/// Procedural LUTs used as the built-in catalog. Avoids shipping `.cube` resources whose
/// extension Xcode doesn't recognize for automatic bundling.
enum BuiltinLUTs {

  static func all() -> [LUT] {
    [
      make(name: "Identity", n: 17) { (r, g, b) in (r, g, b) },
      make(name: "Sepia", n: 17, transform: sepia),
      make(name: "B&W", n: 17, transform: blackAndWhite),
      make(name: "Cool", n: 17, transform: cool),
      make(name: "Warm", n: 17, transform: warm),
    ]
  }

  // MARK: - Generators

  private static func make(
    name: String,
    n: Int,
    transform: (Float, Float, Float) -> (Float, Float, Float)
  ) -> LUT {
    var floats: [Float] = []
    floats.reserveCapacity(n * n * n * 4)
    let denom = Float(n - 1)
    for b in 0..<n {
      let bb = Float(b) / denom
      for g in 0..<n {
        let gg = Float(g) / denom
        for r in 0..<n {
          let rr = Float(r) / denom
          let (R, G, B) = transform(rr, gg, bb)
          floats.append(clamp(R))
          floats.append(clamp(G))
          floats.append(clamp(B))
          floats.append(1)
        }
      }
    }
    let data = floats.withUnsafeBufferPointer { Data(buffer: $0) }
    return LUT(
      id: "builtin:\(name)",
      name: name,
      source: .bundled(name),
      dimension: n,
      cubeData: data
    )
  }

  private static func clamp(_ v: Float) -> Float { min(1, max(0, v)) }

  // MARK: - Transforms

  private static func sepia(_ r: Float, _ g: Float, _ b: Float) -> (Float, Float, Float) {
    let R = 0.393 * r + 0.769 * g + 0.189 * b
    let G = 0.349 * r + 0.686 * g + 0.168 * b
    let B = 0.272 * r + 0.534 * g + 0.131 * b
    return (R, G, B)
  }

  private static func blackAndWhite(_ r: Float, _ g: Float, _ b: Float) -> (Float, Float, Float) {
    let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
    return (y, y, y)
  }

  private static func cool(_ r: Float, _ g: Float, _ b: Float) -> (Float, Float, Float) {
    return (r * 0.92, g * 1.02, b * 1.08 + 0.02)
  }

  private static func warm(_ r: Float, _ g: Float, _ b: Float) -> (Float, Float, Float) {
    return (r * 1.10 + 0.02, g * 1.03, b * 0.90)
  }
}
