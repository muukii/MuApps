import Foundation

enum CubeLUTParseError: Error, Sendable {
  case missingSize
  case unsupported1D
  case badEntryCount(expected: Int, got: Int)
  case malformed(line: Int)
}

enum CubeLUTParser {
  static func parse(
    text: String,
    name: String,
    id: String,
    source: LUT.Source
  ) throws -> LUT {
    var size: Int?
    var floats: [Float] = []
    floats.reserveCapacity(33 * 33 * 33 * 4)

    for (index, raw) in text.split(whereSeparator: \.isNewline).enumerated() {
      let line = raw.trimmingCharacters(in: .whitespaces)
      if line.isEmpty || line.hasPrefix("#") { continue }
      if line.uppercased().hasPrefix("LUT_1D_SIZE") {
        throw CubeLUTParseError.unsupported1D
      }
      if line.uppercased().hasPrefix("LUT_3D_SIZE") {
        let parts = line.split(whereSeparator: \.isWhitespace)
        guard parts.count >= 2, let n = Int(parts[1]) else {
          throw CubeLUTParseError.malformed(line: index)
        }
        size = n
        continue
      }
      let upper = line.uppercased()
      if upper.hasPrefix("TITLE") || upper.hasPrefix("DOMAIN_") { continue }

      let parts = line.split(whereSeparator: \.isWhitespace).compactMap { Float($0) }
      guard parts.count == 3 else {
        throw CubeLUTParseError.malformed(line: index)
      }
      floats.append(parts[0])
      floats.append(parts[1])
      floats.append(parts[2])
      floats.append(1)
    }

    guard let n = size else { throw CubeLUTParseError.missingSize }
    let expected = n * n * n * 4
    guard floats.count == expected else {
      throw CubeLUTParseError.badEntryCount(expected: expected, got: floats.count)
    }

    let data = floats.withUnsafeBufferPointer { Data(buffer: $0) }
    return LUT(id: id, name: name, source: source, dimension: n, cubeData: data)
  }
}
