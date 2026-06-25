import Foundation

struct LUT: Identifiable, Hashable, Sendable {
  enum Source: Hashable, Sendable {
    case bundled(String)
    case userFile(URL)
  }

  let id: String
  let name: String
  let source: Source
  let dimension: Int
  let cubeData: Data
}

enum LUTLoadError: Error, Sendable {
  case unreadable
  case unsupportedFormat
  case parse(String)
}
