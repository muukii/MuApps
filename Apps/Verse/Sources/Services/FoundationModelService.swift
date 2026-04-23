//
//  FoundationModelService.swift
//  YouTubeSubtitle
//
//  Created by Claude on 2025/12/28.
//

import FoundationModels
import SwiftUI

// MARK: - Vocabulary Auto-Fill Response

/// Example sentence structure for auto-fill.
@Generable
struct ExampleSentence: Sendable {
  @Guide(description: "The example sentence in the original language of the term")
  var originalSentence: String

  @Guide(description: "Translation of the example sentence")
  var translatedSentence: String
}

/// Structured response for vocabulary term auto-fill feature.
/// Uses FoundationModels' native @Generable for constrained sampling.
@Generable
struct VocabularyAutoFillResult: Sendable {
  @Guide(description: "The meaning or definition of the term")
  var meaning: String

  @Guide(description: "The part of speech (noun, verb, adjective, adverb, pronoun, preposition, conjunction, interjection, phrase, idiom, or other)")
  var partOfSpeech: String

  @Guide(description: "Example sentences using the term", .count(2))
  var examples: [ExampleSentence]

  @Guide(description: "Additional notes about usage, nuances, or etymology")
  var notes: String
}

// MARK: - Foundation Model Service

/// Service for generating content using Apple Intelligence (FoundationModels).
/// Uses native structured generation with constrained sampling.
@MainActor
@Observable
final class FoundationModelService {

  // MARK: - Types

  enum State: Equatable {
    case idle
    case loading
    case success
    case error(String)
  }

  enum Availability {
    case available
    case unavailable(reason: String)
  }

  // MARK: - Properties

  var state: State = .idle

  static var preferredLanguageCode: String {
    Locale.preferredLanguages.first
      .flatMap { Locale(identifier: $0).language.languageCode?.identifier }
      ?? "en"
  }

  static func languageName(for code: String) -> String {
    Locale.current.localizedString(forLanguageCode: code)
      ?? Locale(identifier: "en").localizedString(forLanguageCode: code)
      ?? code
  }

  // MARK: - Availability

  /// Check if Apple Intelligence is available.
  func checkAvailability() -> Availability {
    let model = SystemLanguageModel.default
    switch model.availability {
    case .available:
      return .available
    case .unavailable(let reason):
      return .unavailable(reason: String(describing: reason))
    }
  }

  var isAvailable: Bool {
    if case .available = checkAvailability() {
      return true
    }
    return false
  }

  // MARK: - Vocabulary Auto-Fill

  /// Generate vocabulary fields using FoundationModels' native structured generation.
  func generateVocabularyAutoFill(
    term: String,
    context: String? = nil,
    targetLanguage: String? = nil
  ) async throws -> VocabularyAutoFillResult {
    let resolvedLanguage = targetLanguage ?? Self.preferredLanguageCode

    state = .loading

    do {
      let languageName = Self.languageName(for: resolvedLanguage)
      let instructions = buildVocabularyInstructions(targetLanguageCode: resolvedLanguage)
      let prompt = buildVocabularyPrompt(term: term, context: context, languageName: languageName)

      let session = LanguageModelSession(
        model: SystemLanguageModel.default,
        instructions: instructions
      )

      // Use native structured generation with constrained sampling
      let response = try await session.respond(
        to: prompt,
        generating: VocabularyAutoFillResult.self
      )

      print("[FoundationModelService] VocabularyAutoFill response: \(response.content)")

      state = .success
      return response.content

    } catch let error as LanguageModelSession.GenerationError {
      print("[FoundationModelService] GenerationError: \(error)")
      let errorMessage = handleGenerationError(error)
      state = .error(errorMessage)
      throw FoundationModelError.generationFailed(errorMessage)

    } catch {
      print("[FoundationModelService] Unknown error: \(error)")
      let errorMessage = error.localizedDescription
      state = .error(errorMessage)
      throw FoundationModelError.unknown(error)
    }
  }

  // MARK: - Text Generation (String output)

  /// Generate a simple text response.
  func generate(prompt: String, instructions: String? = nil) async throws -> String {
    state = .loading

    do {
      let session = LanguageModelSession(
        model: SystemLanguageModel.default,
        instructions: instructions
      )

      let response = try await session.respond(to: prompt)

      state = .success
      return response.content

    } catch let error as LanguageModelSession.GenerationError {
      let errorMessage = handleGenerationError(error)
      state = .error(errorMessage)
      throw FoundationModelError.generationFailed(errorMessage)

    } catch {
      let errorMessage = error.localizedDescription
      state = .error(errorMessage)
      throw FoundationModelError.unknown(error)
    }
  }

  // MARK: - Reset

  func reset() {
    state = .idle
  }

  // MARK: - Private Helpers

  private func buildVocabularyInstructions(targetLanguageCode: String) -> String {
    let languageName = Self.languageName(for: targetLanguageCode)

    return """
    You are a language expert helping users build their vocabulary.
    Generate helpful information for learning a word or phrase.

    Important guidelines:
    - Provide the meaning/definition in \(languageName)
    - Identify the part of speech (noun, verb, adjective, adverb, pronoun, preposition, conjunction, interjection, phrase, idiom, or other)
    - Create 2 example sentences in the original language of the term with their translations in \(languageName)
    - Include useful notes about usage, nuances, common collocations, or etymology
    - Keep responses concise but informative
    """
  }

  private func buildVocabularyPrompt(term: String, context: String?, languageName: String) -> String {
    var prompt = "Term: \(term)"
    if let context = context, !context.isEmpty {
      prompt += "\nContext: \(context)"
    }
    prompt += "\n\nIMPORTANT: You MUST write the meaning and notes in \(languageName). Do not use any other language."
    return prompt
  }

  private func handleGenerationError(_ error: LanguageModelSession.GenerationError) -> String {
    switch error {
    case .exceededContextWindowSize:
      return "The text is too long to process. Please try with a shorter selection."
    case .assetsUnavailable:
      return "Language model assets are not available. Please try again later."
    case .guardrailViolation:
      return "The content violates safety guidelines."
    case .unsupportedLanguageOrLocale:
      return "The language or locale is not supported."
    @unknown default:
      return "An unknown error occurred: \(error)"
    }
  }
}

// MARK: - Foundation Model Error

enum FoundationModelError: LocalizedError {
  case notAvailable(String)
  case generationFailed(String)
  case unknown(any Error)

  var errorDescription: String? {
    switch self {
    case .notAvailable(let reason):
      return reason
    case .generationFailed(let message):
      return message
    case .unknown(let error):
      return error.localizedDescription
    }
  }
}
