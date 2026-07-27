//
//  ExplanationLanguage.swift
//  YouTubeSubtitle
//
//  Created by Claude on 2026/07/28.
//

import Foundation

/// The language AI responses are written in (explanations, vocabulary auto-fill, ChatGPT prompt).
///
/// Stored in `UserDefaults` so both the Settings picker (`@AppStorage`) and the
/// non-View prompt builders read the same value.
enum ExplanationLanguage: String, CaseIterable, Identifiable {
  /// Follows the device's preferred language.
  case system
  case english
  case japanese

  static let storageKey = "explanationLanguage"

  /// The language currently selected in Settings.
  static var current: ExplanationLanguage {
    UserDefaults.standard.string(forKey: storageKey)
      .flatMap(ExplanationLanguage.init(rawValue:))
      ?? .system
  }

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .system:
      return "System"
    case .english:
      return "English"
    case .japanese:
      return "Japanese"
    }
  }

  /// BCP-47 primary language code passed to the on-device model.
  var languageCode: String {
    switch self {
    case .system:
      return Self.deviceLanguageCode
    case .english:
      return "en"
    case .japanese:
      return "ja"
    }
  }

  /// English language name embedded in prompts (e.g. "Japanese"), so the wording
  /// stays stable regardless of the device locale.
  var promptName: String {
    Locale(identifier: "en").localizedString(forLanguageCode: languageCode) ?? "English"
  }

  private static var deviceLanguageCode: String {
    Locale.preferredLanguages.first
      .flatMap { Locale(identifier: $0).language.languageCode?.identifier }
      ?? "en"
  }
}
