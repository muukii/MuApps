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
/// these URLs externally launches the ChatGPT app when it is installed.
struct ChatGPTURLBuilder {
  private static let baseURL = "https://chatgpt.com/"
  private static let promptParameter = "q"

  /// Builds a ChatGPT URL with the given prompt text
  /// - Parameter prompt: The prompt text to send to ChatGPT
  /// - Returns: A URL if successfully built, nil otherwise
  static func buildURL(prompt: String) -> URL? {
    var components = URLComponents(string: baseURL)
    components?.queryItems = [
      URLQueryItem(name: promptParameter, value: prompt)
    ]
    return components?.url
  }

  /// Builds a ChatGPT URL for asking about a word/phrase with context
  /// - Parameters:
  ///   - text: The word or phrase to ask about
  ///   - context: The context in which the word/phrase appeared
  /// - Returns: A URL if successfully built, nil otherwise
  static func buildURL(text: String, context: String) -> URL? {
    buildURL(prompt: ExplanationPrompt.buildFullPrompt(text: text, context: context))
  }
}
