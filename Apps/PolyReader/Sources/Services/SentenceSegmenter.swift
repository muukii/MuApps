import Foundation
import NaturalLanguage

enum SentenceSegmenter {
  static func segment(_ text: String) -> [String] {
    let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedText.isEmpty else { return [] }

    let tokenizer = NLTokenizer(unit: .sentence)
    tokenizer.string = trimmedText

    var sentences: [String] = []
    tokenizer.enumerateTokens(in: trimmedText.startIndex..<trimmedText.endIndex) { range, _ in
      let sentence = String(trimmedText[range]).trimmingCharacters(in: .whitespacesAndNewlines)
      if !sentence.isEmpty {
        sentences.append(sentence)
      }
      return true
    }

    if sentences.isEmpty {
      return fallbackSegment(trimmedText)
    }

    return sentences
  }

  private static func fallbackSegment(_ text: String) -> [String] {
    let delimiters: Set<Character> = [".", "?", "!", "。", "！", "？"]
    var sentences: [String] = []
    var sentenceStart = text.startIndex

    for index in text.indices where delimiters.contains(text[index]) {
      let sentenceEnd = text.index(after: index)
      let sentence = String(text[sentenceStart..<sentenceEnd])
        .trimmingCharacters(in: .whitespacesAndNewlines)

      if !sentence.isEmpty {
        sentences.append(sentence)
      }

      sentenceStart = sentenceEnd
    }

    if sentenceStart < text.endIndex {
      let remainder = String(text[sentenceStart..<text.endIndex])
        .trimmingCharacters(in: .whitespacesAndNewlines)

      if !remainder.isEmpty {
        sentences.append(remainder)
      }
    }

    return sentences.isEmpty ? [text] : sentences
  }
}
