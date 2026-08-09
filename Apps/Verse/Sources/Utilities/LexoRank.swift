//
//  LexoRank.swift
//  YouTubeSubtitle
//
//  Lexicographic ranking utility for string-based ordering.
//  Similar to Figma's LexoRank algorithm for efficient reordering.
//

import Foundation

/// Lexicographic ranking utility for string-based ordering.
/// Uses character range 'a'-'z' for simple, human-readable keys.
enum LexoRank {

  // MARK: - Constants

  private static let minChar: Character = "a"
  private static let maxChar: Character = "z"
  private static let midChar: Character = "m"

  private static var minCharValue: UInt8 { minChar.asciiValue! }
  private static var maxCharValue: UInt8 { maxChar.asciiValue! }
  private static var midCharValue: UInt8 { midChar.asciiValue! }

  // MARK: - Public API

  /// Generate initial order key for first item
  static func initial() -> String {
    String(midChar)
  }

  /// Generate a key that sorts before the given key
  static func before(_ key: String) -> String {
    between(nil, key)
  }

  /// Generate a key that sorts after the given key
  static func after(_ key: String) -> String {
    between(key, nil)
  }

  /// Generate a key between two existing keys
  /// - Parameters:
  ///   - before: Key that should sort before the result (nil = beginning of list)
  ///   - after: Key that should sort after the result (nil = end of list)
  /// - Returns: A new key that sorts between the two
  static func between(_ before: String?, _ after: String?) -> String {
    // Handle edge cases
    if before == nil && after == nil {
      return initial()
    }

    if before == nil {
      return generateBefore(after!)
    }

    if after == nil {
      return generateAfter(before!)
    }

    return generateBetween(before!, after!)
  }

  /// Check if rebalancing is needed: keys getting too long, or duplicate keys
  /// left behind by the earlier `generateBefore` bug that returned "am" for
  /// any key starting with 'a' (existing stores can carry those duplicates).
  static func needsRebalancing(_ keys: [String], threshold: Int = 50) -> Bool {
    keys.contains { $0.count > threshold } || Set(keys).count != keys.count
  }

  /// Generate evenly distributed keys for rebalancing
  static func distributeKeys(count: Int) -> [String] {
    guard count > 0 else { return [] }
    guard count > 1 else { return [initial()] }

    // For small counts, use simple distribution
    if count <= 24 {
      return simpleDistribution(count: count)
    }

    // For larger counts, use multi-character keys
    return multiCharDistribution(count: count)
  }

  // MARK: - Private Implementation

  private static func generateBefore(_ key: String) -> String {
    var result = ""

    for char in key {
      let value = char.asciiValue!

      // Room below this character: place the midpoint and stop.
      if value > minCharValue + 1 {
        result.append(Character(UnicodeScalar((minCharValue + value) / 2)))
        return result
      }

      // 'b' is adjacent to 'a': settle on 'a' and open space with a suffix.
      if value == minCharValue + 1 {
        return result + String(minChar) + String(midChar)
      }

      // 'a': no room at this position, keep it and descend into the next one.
      result.append(char)
    }

    // Empty or all-'a' key. All-'a' keys are unreachable through generated
    // keys (generation never emits a bare trailing 'a'), so return the key
    // itself and let duplicate-triggered rebalancing recover the ordering.
    return result.isEmpty ? initial() : result
  }

  private static func generateAfter(_ key: String) -> String {
    let chars = Array(key)
    guard let lastChar = chars.last else {
      return initial()
    }

    let lastValue = lastChar.asciiValue!

    // If last char is less than 'z', we can increment or use midpoint
    if lastValue < maxCharValue - 1 {
      let midValue = (lastValue + maxCharValue) / 2
      return key.dropLast() + String(Character(UnicodeScalar(midValue)))
    }

    // If we're at 'y' or 'z', append a character
    return key + String(midChar)
  }

  /// Expects `before < after`. Degenerate inputs (equal keys, inverted keys,
  /// or a truly empty gap like "b"/"ba") return a duplicate-or-larger key
  /// instead of trapping; duplicate-triggered rebalancing then recovers.
  private static func generateBetween(_ before: String, _ after: String) -> String {
    let beforeChars = Array(before)
    let afterChars = Array(after)

    // Copy the shared prefix.
    var result = ""
    var i = 0
    while i < beforeChars.count, i < afterChars.count, beforeChars[i] == afterChars[i] {
      result.append(beforeChars[i])
      i += 1
    }

    if i == beforeChars.count {
      if i == afterChars.count {
        // Equal keys — no strictly-between key exists.
        return before + String(midChar)
      }
      // `before` is a strict prefix: any strictly-smaller suffix of
      // `after`'s tail fits the gap.
      return result + generateBefore(String(afterChars[i...]))
    }

    if i == afterChars.count {
      // `after` is a strict prefix of `before`, i.e. inputs are inverted.
      return before + String(midChar)
    }

    // Signed arithmetic: the old UInt8 subtraction trapped when a caller's
    // keys diverged into an inverted tail (e.g. between("by", "ca")).
    let beforeValue = Int(beforeChars[i].asciiValue!)
    let afterValue = Int(afterChars[i].asciiValue!)

    if afterValue - beforeValue >= 2 {
      let midValue = (beforeValue + afterValue) / 2
      return result + String(Character(UnicodeScalar(UInt8(midValue))))
    }

    // Adjacent digits: commit `before`'s digit — any extension of it sorts
    // below `after` — so all that remains is a suffix strictly greater than
    // `before`'s tail, whatever that tail contains.
    result.append(beforeChars[i])
    var j = i + 1
    while j < beforeChars.count {
      let value = Int(beforeChars[j].asciiValue!)
      if value < Int(maxCharValue) - 1 {
        // A larger digit here beats the tail regardless of what follows it.
        let midValue = (value + Int(maxCharValue)) / 2
        result.append(Character(UnicodeScalar(UInt8(midValue))))
        return result
      }
      result.append(beforeChars[j])
      j += 1
    }
    // Tail exhausted (empty or all 'y'/'z'): extend it.
    return result + String(midChar)
  }

  private static func simpleDistribution(count: Int) -> [String] {
    let range = Int(maxCharValue - minCharValue) // 25
    let step = range / (count + 1)

    var keys: [String] = []
    for i in 1...count {
      let charValue = Int(minCharValue) + (step * i)
      let clampedValue = min(charValue, Int(maxCharValue))
      keys.append(String(Character(UnicodeScalar(clampedValue)!)))
    }

    return keys
  }

  private static func multiCharDistribution(count: Int) -> [String] {
    // Grow the key length until every item maps to a distinct slot; clamping
    // into a fixed 2-character space would collide keys for large counts.
    // Digits span 'b'...'y' so distributed keys never carry the boundary
    // characters 'a'/'z' — those create adjacent gaps (like "b"/"ba") that
    // between() cannot split.
    let digitBase = 24
    let firstDigitValue = Int(minCharValue) + 1

    var length = 2
    var totalSlots = digitBase * digitBase
    while totalSlots < count + 2 {
      length += 1
      totalSlots *= digitBase
    }

    let step = totalSlots / (count + 1)

    var keys: [String] = []
    for i in 1...count {
      var slot = step * i
      var chars: [Character] = []
      for _ in 0..<length {
        chars.append(Character(UnicodeScalar(UInt8(firstDigitValue + slot % digitBase))))
        slot /= digitBase
      }
      keys.append(String(chars.reversed()))
    }

    return keys
  }
}
