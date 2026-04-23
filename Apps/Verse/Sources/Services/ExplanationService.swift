//
//  ExplanationService.swift
//  YouTubeSubtitle
//
//  Created by Claude on 2025/12/30.
//

import FoundationModels
import SwiftUI

// MARK: - Phrase Analysis

/// Represents a phrase breakdown with its meaning and grammatical role.
@Generable
struct PhraseAnalysis: Sendable {
  @Guide(description: "The phrase from the text")
  var phrase: String

  @Guide(description: "Meaning of the phrase in user's language")
  var meaning: String

  @Guide(description: "Grammatical role (e.g., subject, verb phrase, object, adverbial)")
  var role: String
}

// MARK: - Idiom Explanation

/// Represents an idiom found in the text with its explanation.
@Generable
struct IdiomExplanation: Sendable {
  @Guide(description: "The idiom or fixed expression found in the text")
  var idiom: String

  @Guide(description: "Meaning of the idiom in user's language")
  var meaning: String

  @Guide(description: "Origin or background of the idiom, or usage notes")
  var origin: String
}

// MARK: - Explanation Response

/// Structured response for word/phrase explanations.
/// Uses FoundationModels' native @Generable for constrained sampling.
@Generable
struct ExplanationResponse: Sendable {
  @Guide(description: "Translation of the word/phrase in the user's language")
  var translation: String

  @Guide(description: "Detailed explanation of the word/phrase including meaning, usage, and nuances")
  var explanation: String

  @Guide(description: "Breakdown of the context sentence into meaningful phrases with their meanings")
  var phrases: [PhraseAnalysis]

  @Guide(description: "Idioms or fixed expressions found in the text. Empty array if none found.")
  var idioms: [IdiomExplanation]
}

// MARK: - Explanation Service

/// Service for generating word/phrase explanations using Apple Intelligence.
/// Uses FoundationModels framework directly for native Apple Intelligence support.
@MainActor
@Observable
final class ExplanationService {

  // MARK: - Types

  enum State: Equatable {
    case idle
    case loading
    case success(String)
    case error(String)
  }

  enum Availability {
    case available
    case unavailable(reason: UnavailabilityReason)

    enum UnavailabilityReason {
      case deviceNotEligible
      case appleIntelligenceNotEnabled
      case modelNotReady
      case unknown(String)

      nonisolated var localizedDescription: String {
        switch self {
        case .deviceNotEligible:
          return "This device does not support Apple Intelligence."
        case .appleIntelligenceNotEnabled:
          return "Please enable Apple Intelligence in Settings."
        case .modelNotReady:
          return "The language model is being downloaded. Please try again later."
        case .unknown(let description):
          return description
        }
      }
    }
  }

  // MARK: - Properties

  var state: State = .idle

  /// Current generation task (for cancellation support)
  /// Using nonisolated(unsafe) because Task.cancel() is thread-safe
  nonisolated(unsafe) private var currentGenerationTask: Task<Void, Never>?

  // MARK: - Language Detection

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
      let reasonString = String(describing: reason)
      if reasonString.contains("deviceNotEligible") {
        return .unavailable(reason: .deviceNotEligible)
      } else if reasonString.contains("appleIntelligenceNotEnabled") {
        return .unavailable(reason: .appleIntelligenceNotEnabled)
      } else if reasonString.contains("modelNotReady") {
        return .unavailable(reason: .modelNotReady)
      } else {
        return .unavailable(reason: .unknown(reasonString))
      }
    }
  }

  var isAvailable: Bool {
    if case .available = checkAvailability() {
      return true
    }
    return false
  }

  // MARK: - Text Generation

  /// Generate an explanation for a word or phrase within its context.
  func explain(
    text: String,
    context: String,
    targetLanguage: String? = nil
  ) async throws -> String {
    let availability = checkAvailability()

    switch availability {
    case .available:
      return try await generateExplanation(
        text: text,
        context: context,
        targetLanguage: targetLanguage
      )

    case .unavailable(let reason):
      state = .error(reason.localizedDescription)
      throw ExplanationError.notAvailable(reason.localizedDescription)
    }
  }

  /// Stream an explanation for a word or phrase.
  func streamExplanation(
    text: String,
    context: String,
    targetLanguage: String? = nil
  ) -> AsyncThrowingStream<String, any Error> {
    let availability = checkAvailability()

    switch availability {
    case .available:
      return streamExplanationImpl(
        text: text,
        context: context,
        targetLanguage: targetLanguage
      )

    case .unavailable(let reason):
      return AsyncThrowingStream { continuation in
        continuation.finish(throwing: ExplanationError.notAvailable(reason.localizedDescription))
      }
    }
  }

  /// Generate a structured explanation for a word or phrase within its context.
  /// Uses FoundationModels' native structured generation with constrained sampling.
  func generateStructuredExplanation(
    text: String,
    context: String,
    targetLanguage: String? = nil
  ) async throws -> ExplanationResponse {
    let availability = checkAvailability()

    switch availability {
    case .available:
      return try await generateStructuredExplanationImpl(
        text: text,
        context: context,
        targetLanguage: targetLanguage
      )

    case .unavailable(let reason):
      state = .error(reason.localizedDescription)
      throw ExplanationError.notAvailable(reason.localizedDescription)
    }
  }

  /// Reset the service state.
  func reset() {
    cancelCurrentGeneration()
    state = .idle
  }

  /// Cancel any ongoing generation.
  func cancelCurrentGeneration() {
    currentGenerationTask?.cancel()
    currentGenerationTask = nil
  }

  // MARK: - Private Implementation

  /// Generate structured explanation using Apple Intelligence.
  private func generateStructuredExplanationImpl(
    text: String,
    context: String,
    targetLanguage: String?
  ) async throws -> ExplanationResponse {
    state = .loading

    do {
      let resolvedLanguage = targetLanguage ?? Self.preferredLanguageCode
      let languageName = Self.languageName(for: resolvedLanguage)
      let instructions = buildStructuredInstructions(languageName: languageName)
      let prompt = buildPrompt(text: text, context: context)

      print("[ExplanationService] Starting structured explanation generation")
      print("[ExplanationService] Target language: \(languageName)")

      let session = LanguageModelSession(
        model: SystemLanguageModel.default,
        instructions: instructions
      )

      // Use native structured generation with constrained sampling
      let response = try await session.respond(
        to: prompt,
        generating: ExplanationResponse.self
      )

      print("[ExplanationService] Structured response: \(response.content)")

      // Build display text for state
      var displayText = """
        ## Translation

        \(response.content.translation)

        ## Explanation

        \(response.content.explanation)
        """

      if !response.content.phrases.isEmpty {
        displayText += "\n\n## Phrases\n"
        for phrase in response.content.phrases {
          displayText += "\n- **\(phrase.phrase)** (\(phrase.role)): \(phrase.meaning)"
        }
      }

      if !response.content.idioms.isEmpty {
        displayText += "\n\n## Idioms\n"
        for idiom in response.content.idioms {
          displayText += "\n- **\(idiom.idiom)**: \(idiom.meaning)\n  _\(idiom.origin)_"
        }
      }

      state = .success(displayText)
      return response.content

    } catch let error as LanguageModelSession.GenerationError {
      let errorMessage = handleGenerationError(error)
      state = .error(errorMessage)
      throw ExplanationError.generationFailed(errorMessage)

    } catch {
      let errorMessage = error.localizedDescription
      state = .error(errorMessage)
      throw ExplanationError.unknown(error)
    }
  }

  /// Generate explanation using Apple Intelligence.
  private func generateExplanation(
    text: String,
    context: String,
    targetLanguage: String?
  ) async throws -> String {
    state = .loading

    do {
      let resolvedLanguage = targetLanguage ?? Self.preferredLanguageCode
      let languageName = Self.languageName(for: resolvedLanguage)
      let instructions = buildInstructions(languageName: languageName)
      let prompt = buildPrompt(text: text, context: context)

      let session = LanguageModelSession(
        model: SystemLanguageModel.default,
        instructions: instructions
      )

      let response = try await session.respond(to: prompt)
      let explanation = response.content

      state = .success(explanation)
      return explanation

    } catch let error as LanguageModelSession.GenerationError {
      let errorMessage = handleGenerationError(error)
      state = .error(errorMessage)
      throw ExplanationError.generationFailed(errorMessage)

    } catch {
      let errorMessage = error.localizedDescription
      state = .error(errorMessage)
      throw ExplanationError.unknown(error)
    }
  }

  /// Stream explanation using Apple Intelligence.
  private func streamExplanationImpl(
    text: String,
    context: String,
    targetLanguage: String?
  ) -> AsyncThrowingStream<String, any Error> {
    // Cancel any previous generation before starting a new one
    currentGenerationTask?.cancel()

    return AsyncThrowingStream { continuation in
      let task = Task { @MainActor in
        do {
          // Check for cancellation before starting
          try Task.checkCancellation()

          print("[ExplanationService] Starting streaming explanation")
          self.state = .loading

          let resolvedLanguage = targetLanguage ?? Self.preferredLanguageCode
          let languageName = Self.languageName(for: resolvedLanguage)
          let instructions = self.buildInstructions(languageName: languageName)
          let prompt = self.buildPrompt(text: text, context: context)

          print("[ExplanationService] Creating session...")
          let session = LanguageModelSession(
            model: SystemLanguageModel.default,
            instructions: instructions
          )

          print("[ExplanationService] Streaming response...")
          var fullContent = ""

          for try await snapshot in session.streamResponse(to: prompt) {
            // Check for cancellation on each chunk
            try Task.checkCancellation()

            if let stringContent = snapshot.content as? String {
              fullContent = stringContent
            } else {
              fullContent = snapshot.rawContent.jsonString
            }
            continuation.yield(fullContent)
          }

          print("[ExplanationService] Stream finished successfully")
          self.state = .success(fullContent)
          continuation.finish()

        } catch is CancellationError {
          print("[ExplanationService] Generation cancelled")
          continuation.finish()

        } catch let error as LanguageModelSession.GenerationError {
          print("[ExplanationService] GenerationError: \(error)")
          let errorMessage = self.handleGenerationError(error)
          self.state = .error(errorMessage)
          continuation.finish(throwing: ExplanationError.generationFailed(errorMessage))

        } catch {
          print("[ExplanationService] Unknown error: \(error)")
          let errorMessage = error.localizedDescription
          self.state = .error(errorMessage)
          continuation.finish(throwing: ExplanationError.unknown(error))
        }
      }

      // Store the task for cancellation support
      self.currentGenerationTask = task

      // Handle stream termination
      continuation.onTermination = { @Sendable _ in
        task.cancel()
      }
    }
  }

  // MARK: - Prompt Building

  private func buildInstructions(languageName: String) -> String {
    ExplanationPrompt.buildSystemInstruction(targetLanguage: languageName)
  }

  private func buildStructuredInstructions(languageName: String) -> String {
    """
    You are a language expert helping users understand words and phrases in English.

    Important guidelines:
    - Provide the translation in \(languageName)
    - Provide a detailed explanation in \(languageName)
    - Consider the context when explaining meaning and usage

    For phrase analysis:
    - Break down the context sentence into meaningful phrases
    - For each phrase, provide its meaning in \(languageName) and its grammatical role
    - Grammatical roles include: subject, verb phrase, object, complement, adverbial, prepositional phrase, etc.

    For idiom detection:
    - Identify any idioms, fixed expressions, or phrasal verbs in the text
    - Explain their meaning in \(languageName)
    - Provide origin or usage notes when available
    - If no idioms are found, return an empty array
    """
  }

  private func buildPrompt(text: String, context: String) -> String {
    ExplanationPrompt.buildUserPrompt(text: text, context: context)
  }

  // MARK: - Error Handling

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

// MARK: - Explanation Error

enum ExplanationError: LocalizedError {
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

// MARK: - Preview Support

extension ExplanationService {
  /// Create a mock service for previews
  static func preview(state: State = .idle) -> ExplanationService {
    let service = ExplanationService()
    service.state = state
    return service
  }
}
