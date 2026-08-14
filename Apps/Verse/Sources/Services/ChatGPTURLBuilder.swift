//
//  ChatGPTURLBuilder.swift
//  YouTubeSubtitle
//
//  Created by Claude on 2025/01/04.
//

import Foundation

// MARK: - ChatGPT URL Builder

/// Builds URLs for opening ChatGPT with a prompt.
///
/// `chatgpt.com` claims `/` with a `q` parameter as a universal link, so opening
/// these URLs externally launches the ChatGPT app when it is installed. Verse
/// also requests a temporary chat for explanation prompts.
struct ChatGPTURLBuilder {
  private static let baseURL = "https://chatgpt.com/"
  private static let promptParameter = "q"
  private static let temporaryChatParameter = "temporary-chat"

  /// Builds a ChatGPT URL with the given prompt text
  /// - Parameter prompt: The prompt text to send to ChatGPT
  /// - Returns: A URL if successfully built, nil otherwise
  static func buildURL(prompt: String) -> URL? {
    var components = URLComponents(string: baseURL)
    components?.queryItems = [
      URLQueryItem(name: promptParameter, value: prompt),
      URLQueryItem(name: temporaryChatParameter, value: "true"),
    ]
    return components?.url
  }

  /// Builds a ChatGPT URL for asking about English text in context.
  /// - Parameters:
  ///   - text: The exact English text to ask about.
  ///   - context: Surrounding source text used to interpret `text`.
  /// - Returns: A URL if the prompt and URL can be built; otherwise, `nil`.
  static func buildURL(text: String, context: String) -> URL? {
    guard let prompt = try? ExplanationPrompt.buildFullPrompt(text: text, context: context)
    else { return nil }
    return buildURL(prompt: prompt)
  }
}
