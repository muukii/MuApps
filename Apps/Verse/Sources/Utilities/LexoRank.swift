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

  /// Check if rebalancing is needed (keys getting too long)
  static func needsRebalancing(_ keys: [String], threshold: Int = 50) -> Bool {
    keys.contains { $0.count > threshold }
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
    let chars = Array(key)
    guard let firstChar = chars.first else {
      return initial()
    }

    let firstValue = firstChar.asciiValue!

    // If first char is greater than 'a', we can use the midpoint
    if firstValue > minCharValue + 1 {
      let midValue = (minCharValue + firstValue) / 2
      return String(Character(UnicodeScalar(midValue)))
    }

    // If first char is 'a' or 'b', append to 'a'
    if firstValue <= minCharValue + 1 {
      // Generate before first char by using 'a' + midpoint suffix
      return String(minChar) + String(midChar)
    }

    return String(Character(UnicodeScalar((minCharValue + firstValue) / 2)))
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

  private static func generateBetween(_ before: String, _ after: String) -> String {
    let beforeChars = Array(before)
    let afterChars = Array(after)

    var result = ""
    var i = 0

    while true {
      let beforeChar = i < beforeChars.count ? beforeChars[i] : minChar
      let afterChar = i < afterChars.count ? afterChars[i] : maxChar

      let beforeValue = beforeChar.asciiValue!
      let afterValue = afterChar.asciiValue!

      // If characters are the same, continue to next position
      if beforeValue == afterValue {
        result.append(beforeChar)
        i += 1
        continue
      }

      // If there's room between the characters
      if afterValue - beforeValue > 1 {
        let midValue = (beforeValue + afterValue) / 2
        result.append(Character(UnicodeScalar(midValue)))
        return result
      }

      // Characters are adjacent (e.g., 'a' and 'b')
      // Use the lower character and extend with a suffix
      result.append(beforeChar)
      i += 1

      // Now find a character between beforeChars[i] (or 'a') and 'z'
      let nextBeforeChar = i < beforeChars.count ? beforeChars[i] : minChar
      let nextBeforeValue = nextBeforeChar.asciiValue!

      if maxCharValue - nextBeforeValue > 1 {
        let midValue = (nextBeforeValue + maxCharValue) / 2
        result.append(Character(UnicodeScalar(midValue)))
        return result
      }

      // Continue the process
      continue
    }
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
    // Use 2-character keys for larger counts
    var keys: [String] = []
    let totalSlots = 26 * 26 // 676 possible 2-char combinations

    let step = max(1, totalSlots / (count + 1))

    for i in 1...count {
      let slot = step * i
      let firstCharIndex = slot / 26
      let secondCharIndex = slot % 26

      let firstChar = Character(UnicodeScalar(Int(minCharValue) + min(firstCharIndex, 25))!)
      let secondChar = Character(UnicodeScalar(Int(minCharValue) + secondCharIndex)!)

      keys.append(String(firstChar) + String(secondChar))
    }

    return keys
  }
}
