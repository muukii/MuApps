//
//  Identified.swift
//  YouTubeSubtitle
//
//  Created by Claude on 2025/12/27.
//

import Foundation

/// A generic wrapper that makes any value identifiable for use with SwiftUI's `.sheet(item:)`.
///
/// Usage:
/// ```swift
/// @State private var selectedWord: Identified<String>?
///
/// .sheet(item: $selectedWord) { item in
///   WordDetailSheet(word: item.value)
/// }
///
/// // To present:
/// selectedWord = Identified("hello")
/// ```
struct Identified<Value>: Identifiable {
  let id = UUID()
  let value: Value

  init(_ value: Value) {
    self.value = value
  }
}
