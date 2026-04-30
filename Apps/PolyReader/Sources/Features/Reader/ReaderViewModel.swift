import Foundation
import Observation
import SwiftData

@Observable
final class ReaderViewModel {
  var sentences: [String] = []
  var currentIndex: Int = 0
  var isPlaying: Bool = false
  var wordsPerMinute: Double = 180

  @ObservationIgnored private var readingText: ReadingText?
  @ObservationIgnored private var modelContext: ModelContext?
  @ObservationIgnored private var advanceTask: Task<Void, Never>?

  var currentSentence: String {
    guard sentences.indices.contains(currentIndex) else { return "" }
    return sentences[currentIndex]
  }

  var progress: Double {
    guard !sentences.isEmpty else { return 0 }
    return Double(currentIndex + 1) / Double(sentences.count)
  }

  var positionText: String {
    guard !sentences.isEmpty else { return "0 / 0" }
    return "\(currentIndex + 1) / \(sentences.count)"
  }

  var canGoBackward: Bool {
    currentIndex > 0
  }

  var canGoForward: Bool {
    currentIndex < sentences.count - 1
  }

  func configure(readingText: ReadingText, modelContext: ModelContext) {
    self.readingText = readingText
    self.modelContext = modelContext
    self.sentences = SentenceSegmenter.segment(readingText.body)
    self.currentIndex = clampedIndex(readingText.currentSentenceIndex)
    self.isPlaying = false
    advanceTask?.cancel()
    advanceTask = nil
  }

  func togglePlayback() {
    if isPlaying {
      pause()
    } else {
      play()
    }
  }

  func play() {
    guard !sentences.isEmpty else { return }
    guard currentIndex < sentences.count - 1 else {
      isPlaying = false
      return
    }

    isPlaying = true
    scheduleNextAdvance()
  }

  func pause() {
    isPlaying = false
    advanceTask?.cancel()
    advanceTask = nil
  }

  func next() {
    guard canGoForward else {
      pause()
      return
    }

    currentIndex += 1
    persistPosition()
    rescheduleIfPlaying()
  }

  func previous() {
    guard canGoBackward else { return }

    currentIndex -= 1
    persistPosition()
    rescheduleIfPlaying()
  }

  func restart() {
    currentIndex = 0
    persistPosition()
    rescheduleIfPlaying()
  }

  func rescheduleIfPlaying() {
    guard isPlaying else { return }
    scheduleNextAdvance()
  }

  func persistPosition() {
    guard let readingText else { return }

    readingText.currentSentenceIndex = clampedIndex(currentIndex)
    readingText.updatedAt = Date()
    try? modelContext?.save()
  }

  private func scheduleNextAdvance() {
    advanceTask?.cancel()

    guard isPlaying, canGoForward else {
      pause()
      return
    }

    let delay = displayDuration(for: currentSentence)
    let nanoseconds = UInt64(delay * 1_000_000_000)

    advanceTask = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: nanoseconds)
      guard !Task.isCancelled else { return }
      self?.advanceFromTimer()
    }
  }

  private func advanceFromTimer() {
    guard isPlaying else { return }

    if canGoForward {
      currentIndex += 1
      persistPosition()
      scheduleNextAdvance()
    } else {
      pause()
    }
  }

  private func clampedIndex(_ index: Int) -> Int {
    guard !sentences.isEmpty else { return 0 }
    return min(max(index, 0), sentences.count - 1)
  }

  private func displayDuration(for sentence: String) -> TimeInterval {
    let words = max(sentence.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count, 1)
    let seconds = (Double(words) / wordsPerMinute) * 60
    return max(seconds, 1.2)
  }
}
