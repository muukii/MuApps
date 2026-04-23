//
//  VocabularyService.swift
//  YouTubeSubtitle
//
//  Created by Claude on 2025/12/10.
//

import Foundation
import SwiftData

/// Service for managing vocabulary items with CRUD operations.
/// Follows the existing pattern from VideoItemService.
@Observable
@MainActor
final class VocabularyService {

  private let modelContext: ModelContext

  init(modelContext: ModelContext) {
    self.modelContext = modelContext
  }

  // MARK: - Create

  /// How to handle duplicate terms
  enum DuplicateHandling: Sendable {
    /// Do nothing if duplicate exists (default for tap-to-add)
    case skip
    /// Update meaning of existing item if not already set
    case updateMeaning
    /// Create duplicate anyway
    case allowDuplicate
  }

  /// Result of adding an item
  enum AddResult: Sendable {
    case created(item: VocabularyItem)
    case skipped(existing: VocabularyItem)
    case updated(existing: VocabularyItem)

    var item: VocabularyItem {
      switch self {
      case .created(let item), .skipped(let item), .updated(let item):
        return item
      }
    }
  }

  /// Example input for creating vocabulary examples.
  struct ExampleInput: Sendable {
    let originalSentence: String
    let translatedSentence: String
  }

  /// Add a new vocabulary item.
  /// Returns the result of duplicate checking.
  @discardableResult
  func addItem(
    term: String,
    meaning: String? = nil,
    notes: String? = nil,
    partOfSpeech: PartOfSpeech? = nil,
    examples: [ExampleInput] = [],
    duplicateHandling: DuplicateHandling = .skip
  ) throws -> AddResult {
    // Check for existing item with same term (case-insensitive)
    if let existing = try findItemByTerm(term) {
      switch duplicateHandling {
      case .skip:
        return .skipped(existing: existing)

      case .updateMeaning:
        // Update meaning if provided and existing is nil
        if let newMeaning = meaning, existing.meaning == nil {
          existing.meaning = newMeaning
          existing.updatedAt = Date()
        }
        try modelContext.save()
        return .updated(existing: existing)

      case .allowDuplicate:
        break // Continue to create new item
      }
    }

    let item = VocabularyItem(
      term: term,
      meaning: meaning,
      notes: notes,
      partOfSpeech: partOfSpeech
    )

    modelContext.insert(item)

    // Add examples with LexoRank sort ordering
    for (index, example) in examples.enumerated() {
      let sortOrder: String
      if index == 0 {
        sortOrder = LexoRank.initial()
      } else {
        let keys = LexoRank.distributeKeys(count: index + 1)
        sortOrder = keys[index]
      }

      let vocabularyExample = VocabularyExample(
        sortOrder: sortOrder,
        originalSentence: example.originalSentence,
        translatedSentence: example.translatedSentence
      )
      vocabularyExample.vocabularyItem = item
      modelContext.insert(vocabularyExample)
    }

    try modelContext.save()

    return .created(item: item)
  }

  // MARK: - Read

  /// Fetch all vocabulary items sorted by creation date (newest first).
  func fetchAll() throws -> [VocabularyItem] {
    let descriptor = FetchDescriptor<VocabularyItem>(
      sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
    )
    return try modelContext.fetch(descriptor)
  }

  /// Fetch items with pagination.
  func fetchAll(limit: Int, offset: Int = 0) throws -> [VocabularyItem] {
    var descriptor = FetchDescriptor<VocabularyItem>(
      sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
    )
    descriptor.fetchLimit = limit
    descriptor.fetchOffset = offset
    return try modelContext.fetch(descriptor)
  }

  /// Fetch items by learning state.
  func fetchByLearningState(_ state: VocabularyItem.LearningState) throws -> [VocabularyItem] {
    let stateRaw = state.rawValue
    let descriptor = FetchDescriptor<VocabularyItem>(
      predicate: #Predicate { $0._learningState == stateRaw },
      sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
    )
    return try modelContext.fetch(descriptor)
  }

  /// Find item by exact term match (case-insensitive).
  func findItemByTerm(_ term: String) throws -> VocabularyItem? {
    let normalizedTerm = term.lowercased().trimmingCharacters(in: .whitespaces)
    let descriptor = FetchDescriptor<VocabularyItem>(
      predicate: #Predicate { $0._termLowercase == normalizedTerm }
    )
    return try modelContext.fetch(descriptor).first
  }

  /// Search items containing the query in term (case-insensitive).
  func search(query: String) throws -> [VocabularyItem] {
    guard !query.isEmpty else { return try fetchAll() }

    let lowercaseQuery = query.lowercased()
    let descriptor = FetchDescriptor<VocabularyItem>(
      predicate: #Predicate { item in
        item._termLowercase.contains(lowercaseQuery)
      },
      sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
    )
    return try modelContext.fetch(descriptor)
  }

  /// Fetch items due for review.
  func fetchDueForReview() throws -> [VocabularyItem] {
    let now = Date()
    let descriptor = FetchDescriptor<VocabularyItem>(
      predicate: #Predicate { item in
        item.nextReviewDate != nil && item.nextReviewDate! <= now
      },
      sortBy: [SortDescriptor(\.nextReviewDate, order: .forward)]
    )
    return try modelContext.fetch(descriptor)
  }

  /// Get total count of vocabulary items.
  func count() throws -> Int {
    let descriptor = FetchDescriptor<VocabularyItem>()
    return try modelContext.fetchCount(descriptor)
  }

  // MARK: - Update

  /// Update a vocabulary item's content.
  func updateItem(
    _ item: VocabularyItem,
    term: String? = nil,
    meaning: String? = nil,
    notes: String? = nil,
    partOfSpeech: PartOfSpeech?? = nil,
    examples: [ExampleInput]? = nil
  ) throws {
    if let term {
      item.updateTerm(term)
    }
    if let meaning {
      item.meaning = meaning
      item.updatedAt = Date()
    }
    if let notes {
      item.notes = notes
      item.updatedAt = Date()
    }
    // Handle double optional: nil = no change, .some(nil) = clear, .some(.some(value)) = set
    if let partOfSpeechValue = partOfSpeech {
      item.partOfSpeech = partOfSpeechValue
      item.updatedAt = Date()
    }

    // Update examples if provided
    if let newExamples = examples {
      // Delete existing examples
      for example in item.examples ?? [] {
        modelContext.delete(example)
      }

      // Add new examples with LexoRank sort ordering
      let keys = LexoRank.distributeKeys(count: newExamples.count)
      for (index, example) in newExamples.enumerated() {
        let vocabularyExample = VocabularyExample(
          sortOrder: keys.isEmpty ? LexoRank.initial() : keys[index],
          originalSentence: example.originalSentence,
          translatedSentence: example.translatedSentence
        )
        vocabularyExample.vocabularyItem = item
        modelContext.insert(vocabularyExample)
      }

      item.updatedAt = Date()
    }

    try modelContext.save()
  }

  /// Update learning state (for spaced repetition).
  func updateLearningState(
    _ item: VocabularyItem,
    state: VocabularyItem.LearningState,
    nextReviewDate: Date? = nil
  ) throws {
    item.learningState = state
    item.reviewCount += 1
    item.nextReviewDate = nextReviewDate
    item.updatedAt = Date()

    try modelContext.save()
  }

  // MARK: - Delete

  /// Delete a single vocabulary item.
  func deleteItem(_ item: VocabularyItem) throws {
    modelContext.delete(item)
    try modelContext.save()
  }

  /// Delete multiple vocabulary items.
  func deleteItems(_ items: [VocabularyItem]) throws {
    for item in items {
      modelContext.delete(item)
    }
    try modelContext.save()
  }

  /// Delete all vocabulary items.
  func deleteAll() throws {
    let items = try fetchAll()
    for item in items {
      modelContext.delete(item)
    }
    try modelContext.save()
  }

  // MARK: - Statistics

  /// Get count of items by learning state.
  func countByLearningState() throws -> [VocabularyItem.LearningState: Int] {
    let allItems = try fetchAll()
    var counts: [VocabularyItem.LearningState: Int] = [:]

    for state in VocabularyItem.LearningState.allCases {
      counts[state] = allItems.filter { $0.learningState == state }.count
    }

    return counts
  }
}
