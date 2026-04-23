//
//  VocabularyItem.swift
//  YouTubeSubtitle
//
//  Created by Claude on 2025/12/10.
//

import Foundation
import SwiftData
import TypedIdentifier

// MARK: - Part of Speech

/// Represents the grammatical category of a vocabulary term.
enum PartOfSpeech: String, Codable, CaseIterable, Sendable {
  case noun
  case verb
  case adjective
  case adverb
  case pronoun
  case preposition
  case conjunction
  case interjection
  case phrase
  case idiom
  case other

  var displayName: String {
    switch self {
    case .noun: return "Noun"
    case .verb: return "Verb"
    case .adjective: return "Adjective"
    case .adverb: return "Adverb"
    case .pronoun: return "Pronoun"
    case .preposition: return "Preposition"
    case .conjunction: return "Conjunction"
    case .interjection: return "Interjection"
    case .phrase: return "Phrase"
    case .idiom: return "Idiom"
    case .other: return "Other"
    }
  }
}

// MARK: - Vocabulary Example

/// Represents an example sentence for a vocabulary term.
/// Uses SwiftData relationship with VocabularyItem.
@Model
final class VocabularyExample {
  var id: UUID = UUID()

  /// Lexicographic order key for sorting (VideoItem pattern)
  var sortOrder: String?

  /// The example sentence in the original language
  var originalSentence: String = ""

  /// Translation of the example sentence
  var translatedSentence: String = ""

  /// Parent vocabulary item (inverse of VocabularyItem.examples)
  var vocabularyItem: VocabularyItem?

  init(sortOrder: String?, originalSentence: String, translatedSentence: String) {
    self.id = UUID()
    self.sortOrder = sortOrder
    self.originalSentence = originalSentence
    self.translatedSentence = translatedSentence
  }
}

// MARK: - Vocabulary Item

/// Represents a vocabulary item (saved word/phrase/expression) for language learning.
/// Independent of videos - vocabulary items are managed as a standalone collection.
@Model
final class VocabularyItem: TypedIdentifiable {

  typealias TypedIdentifierRawValue = UUID

  var typedID: TypedIdentifier<VocabularyItem> {
    .init(id)
  }

  // MARK: - Core Properties

  var id: UUID

  /// The term (word, phrase, or expression) being saved
  var term: String

  /// The meaning/definition (user-provided or LLM-generated)
  var meaning: String?

  /// User-added notes
  var notes: String?

  /// Timestamp when the item was created
  var createdAt: Date

  /// Timestamp when the item was last updated
  var updatedAt: Date

  // MARK: - Internal Storage

  /// Lowercase term for case-insensitive duplicate checking (SwiftData optimization)
  internal var _termLowercase: String

  /// Learning state stored as String (SwiftData optimization)
  internal var _learningState: String

  /// Part of speech stored as String (SwiftData optimization)
  internal var _partOfSpeech: String?

  /// Review count for spaced repetition
  var reviewCount: Int

  /// Next review date (for spaced repetition)
  var nextReviewDate: Date?

  // MARK: - Relationships

  /// Example sentences (cascade delete when vocabulary item is deleted)
  @Relationship(deleteRule: .cascade, inverse: \VocabularyExample.vocabularyItem)
  var examples: [VocabularyExample]?

  // MARK: - Learning State Enum

  enum LearningState: String, Codable, CaseIterable, Sendable {
    case new
    case learning
    case reviewing
    case mastered
  }

  var learningState: LearningState {
    get { LearningState(rawValue: _learningState) ?? .new }
    set { _learningState = newValue.rawValue }
  }

  // MARK: - Part of Speech

  var partOfSpeech: PartOfSpeech? {
    get { _partOfSpeech.flatMap { PartOfSpeech(rawValue: $0) } }
    set { _partOfSpeech = newValue?.rawValue }
  }

  /// Sorted examples by sortOrder (computed)
  var sortedExamples: [VocabularyExample] {
    (examples ?? []).sorted { ($0.sortOrder ?? "") < ($1.sortOrder ?? "") }
  }

  // MARK: - Initialization

  init(
    term: String,
    meaning: String? = nil,
    notes: String? = nil,
    partOfSpeech: PartOfSpeech? = nil
  ) {
    self.id = UUID()
    self.term = term
    self._termLowercase = term.lowercased().trimmingCharacters(in: .whitespaces)
    self.meaning = meaning
    self.notes = notes
    self._partOfSpeech = partOfSpeech?.rawValue
    self.createdAt = Date()
    self.updatedAt = Date()
    self._learningState = LearningState.new.rawValue
    self.reviewCount = 0
    self.nextReviewDate = nil
  }

  // MARK: - Update Helpers

  /// Updates the term and its lowercase index
  func updateTerm(_ newTerm: String) {
    self.term = newTerm
    self._termLowercase = newTerm.lowercased().trimmingCharacters(in: .whitespaces)
    self.updatedAt = Date()
  }
}
