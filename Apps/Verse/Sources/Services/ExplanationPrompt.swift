//
//  ExplanationPrompt.swift
//  YouTubeSubtitle
//
//  Created by Claude on 2025/12/25.
//

import Foundation

/// Shared prompt builder for word/phrase explanations.
/// Used by both on-device LLM (LLMService) and external services (Gemini).
struct ExplanationPrompt {

  // MARK: - Device Language

  /// Returns the user's preferred language name for LLM responses.
  /// Uses Locale.preferredLanguages which reflects the user's system language settings.
  /// For example: "Japanese", "English", "French", etc.
  static var deviceLanguage: String {
    // Get the user's preferred language from system settings
    guard let preferredLanguage = Locale.preferredLanguages.first else {
      return "English"
    }
    // Extract the language code (e.g., "ja" from "ja-JP")
    let languageCode = Locale(identifier: preferredLanguage).language.languageCode?.identifier ?? preferredLanguage
    return Locale(identifier: "en").localizedString(forLanguageCode: languageCode) ?? "English"
  }

  // MARK: - Default Instructions

  static let defaultSystemInstruction = """
    <Prerequisite>
    You are a language expert.
    Respect the <UserLanguage> specified.
    </Prerequisite>
    <InputFormat>
      <Target>
        The word/phrase the user wants explained
      </Target>
      <Context>
        The surrounding information context where the word/phrase appears
      </Context>
    </InputFormat>

    <OutputFormat type=markdown>
    ## Input
    
    <Target> as original
    
    ## Translation
    
    Translations of <Target> in <UserLanguage>
    
    ## Explanation
    
    Explains the meaning of <Target> in detail, considering various nuances and usages in <UserLanguage>.
    
    </OutputFormat>   

    <Instructions>
      Make response following <OutputFormat>
    </Instructions>    
    """

  static let defaultUserPromptTemplate = """
    <Target>
    
    {text}
    
    </Target>

    <Context>
    
    {context}
    
    </Context>
    """

  // MARK: - Prompt Building

  /// Builds the system instruction with language specification.
  /// - Parameter targetLanguage: The language for the response (defaults to device language)
  /// - Returns: Complete system instruction string
  static func buildSystemInstruction(
    customInstruction: String? = nil,
    targetLanguage: String? = nil
  ) -> String {
    let baseInstruction = customInstruction?.isEmpty == false
      ? customInstruction!
      : defaultSystemInstruction
    let language = targetLanguage ?? deviceLanguage
    return """
      <Instruction>
      \(baseInstruction)
      </Instruction>
      
      <UserLanguage>
      \(language)
      </UserLanguage>            
      """
  }

  /// Builds the user prompt with text and context.
  /// - Parameters:
  ///   - text: The word or phrase to explain
  ///   - context: The surrounding context
  ///   - customTemplate: Custom user prompt template (optional)
  /// - Returns: Complete user prompt string
  static func buildUserPrompt(
    text: String,
    context: String,
    customTemplate: String? = nil
  ) -> String {
    let template = customTemplate?.isEmpty == false
      ? customTemplate!
      : defaultUserPromptTemplate

    return template
      .replacingOccurrences(of: "{text}", with: text)
      .replacingOccurrences(of: "{context}", with: context)
  }

  /// Builds the complete prompt (system instruction + user prompt).
  /// - Parameters:
  ///   - text: The word or phrase to explain
  ///   - context: The surrounding context
  ///   - customSystemInstruction: Custom system instruction (optional)
  ///   - customUserPromptTemplate: Custom user prompt template (optional)
  ///   - targetLanguage: The language for the response (defaults to device language)
  /// - Returns: Complete prompt string
  static func buildFullPrompt(
    text: String,
    context: String,
    customSystemInstruction: String? = nil,
    customUserPromptTemplate: String? = nil,
    targetLanguage: String? = nil
  ) -> String {
    let systemInstruction = buildSystemInstruction(
      customInstruction: customSystemInstruction,
      targetLanguage: targetLanguage
    )
    let userPrompt = buildUserPrompt(
      text: text,
      context: context,
      customTemplate: customUserPromptTemplate
    )

    return """
      <SystemInstruction>
      \(systemInstruction)
      </SystemInstruction>
      
      <UserPrompt>
      \(userPrompt)
      </UserPrompt>      
      """
  }
}
