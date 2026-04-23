//
//  WordExplanationView.swift
//  YouTubeSubtitle
//
//  Created by Claude on 2025/01/04.
//

import SwiftUI
#if os(iOS)
import SafariServices
#endif

// MARK: - Gemini URL Builder

/// Builds URLs for opening Google Gemini with a prompt
struct GeminiURLBuilder {
  private static let baseURL = "https://gemini.google.com"
  private static let promptParameter = "prompt_text"

  /// Builds a Gemini URL with the given prompt text
  /// - Parameter prompt: The prompt text to send to Gemini
  /// - Returns: A URL if successfully built, nil otherwise
  static func buildURL(prompt: String) -> URL? {
    var components = URLComponents(string: baseURL)
    components?.queryItems = [
      URLQueryItem(name: promptParameter, value: prompt)
    ]

    if let url = components?.url {
      print("[GeminiURLBuilder] URL length: \(url.absoluteString.count)")
      return url
    }
    return nil
  }

  /// Builds a Gemini URL for asking about a word/phrase with context
  /// Uses the same prompt format as the on-device LLM (via ExplanationPrompt)
  /// - Parameters:
  ///   - text: The word or phrase to ask about
  ///   - context: The context in which the word/phrase appeared
  /// - Returns: A URL if successfully built, nil otherwise
  static func buildURL(text: String, context: String) -> URL? {
    // Use the shared ExplanationPrompt component (same format as LLMService)
    let prompt = ExplanationPrompt.buildFullPrompt(text: text, context: context)
    return buildURL(prompt: prompt)
  }
}

// MARK: - Safari View (iOS only)

#if os(iOS)
/// SwiftUI wrapper for SFSafariViewController
struct SafariView: UIViewControllerRepresentable {
  let url: URL

  func makeUIViewController(context: Context) -> SFSafariViewController {
    let configuration = SFSafariViewController.Configuration()
    configuration.entersReaderIfAvailable = false
    configuration.barCollapsingEnabled = true
    let safari = SFSafariViewController(url: url, configuration: configuration)
    return safari
  }

  func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {
    // No updates needed
  }
}
#endif

// MARK: - URL Identifiable Extension

extension URL: @retroactive Identifiable {
  public var id: String { absoluteString }
}

// MARK: - Word Explanation View (List-Hosted Component)

/// Embeddable view for displaying Apple Intelligence-generated word/phrase explanations.
/// Designed to be hosted inside a List - renders as List sections.
/// This component manages its own state (ExplanationService, Task management).
struct WordExplanationView: View {
  let service: ExplanationService
  let text: String
  let context: String
  @Binding var geminiURL: URL?

  @State private var translation: String = ""
  @State private var explanation: String = ""
  @State private var phrases: [PhraseAnalysis] = []
  @State private var idioms: [IdiomExplanation] = []
  @State private var generationTask: Task<Void, Never>?

  var body: some View {
    let _ = Self._printChanges()
    Group {
      geminiSection
      translationSection
      explanationSection
      phrasesSection
      idiomsSection
    }
    .onAppear {
      generationTask = Task {
        await generateExplanation()
      }
    }
    .onDisappear {
      generationTask?.cancel()
      generationTask = nil
    }
  }

  // MARK: - Sections

  private var translationSection: some View {
    Section {
      contentView(
        text: translation,
        isLoading: service.state == .loading && translation.isEmpty
      )
    } header: {
      Text("Translation")
        .textCase(nil)
    }
  }

  private var explanationSection: some View {
    Section {
      switch service.state {
      case .error(let message):
        errorView(message: message)
      default:
        contentView(
          text: explanation,
          isLoading: service.state == .loading && explanation.isEmpty
        )
      }
    } header: {
      Text("Explanation")
        .textCase(nil)
    }
  }

  @ViewBuilder
  private var phrasesSection: some View {
    if !phrases.isEmpty {
      Section {
        ForEach(phrases, id: \.phrase) { phrase in
          VStack(alignment: .leading, spacing: 4) {
            HStack {
              Text(phrase.phrase)
                .font(.body.bold())
              Spacer()
              Text(phrase.role)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(.secondary.opacity(0.15))
                .clipShape(Capsule())
            }
            Text(phrase.meaning)
              .font(.subheadline)
              .foregroundStyle(.secondary)
          }
          .padding(.vertical, 2)
        }
      } header: {
        Text("Phrases")
          .textCase(nil)
      }
    } else if service.state == .loading {
      Section {
        HStack(spacing: 8) {
          ProgressView()
          Text("Analyzing phrases...")
            .foregroundStyle(.secondary)
        }
      } header: {
        Text("Phrases")
          .textCase(nil)
      }
    }
  }

  @ViewBuilder
  private var idiomsSection: some View {
    if !idioms.isEmpty {
      Section {
        ForEach(idioms, id: \.idiom) { idiom in
          VStack(alignment: .leading, spacing: 4) {
            Text(idiom.idiom)
              .font(.body.bold())
            Text(idiom.meaning)
              .font(.subheadline)
            Text(idiom.origin)
              .font(.caption)
              .foregroundStyle(.secondary)
              .italic()
          }
          .padding(.vertical, 2)
        }
      } header: {
        Label("Idioms", systemImage: "text.quote")
          .textCase(nil)
      }
    }
  }

  private var geminiSection: some View {
    Section {
      Button {
        geminiURL = GeminiURLBuilder.buildURL(text: text, context: context)
      } label: {
        Label("Ask Gemini", systemImage: "sparkle.magnifyingglass")
      }

      ShareLink(
        item: ExplanationPrompt.buildFullPrompt(text: text, context: context)
      ) {
        Label("Share Prompt", systemImage: "square.and.arrow.up")
      }
    }
  }

  // MARK: - Content Views

  @ViewBuilder
  private func contentView(text: String, isLoading: Bool) -> some View {
    if isLoading {
      HStack(spacing: 8) {
        ProgressView()
        Text("Generating...")
          .foregroundStyle(.secondary)
      }
    } else if text.isEmpty {
      Text("—")
        .foregroundStyle(.tertiary)
    } else {
      Text(markdownAttributedString(from: text))
        .font(.body)
        .textSelection(.enabled)
    }
  }

  private func errorView(message: String) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange)
        Text("Unable to generate")
          .fontWeight(.medium)
      }

      Text(message)
        .font(.caption)
        .foregroundStyle(.secondary)

      Button {
        retryExplanation()
      } label: {
        Label("Try Again", systemImage: "arrow.clockwise")
      }
      .buttonStyle(.bordered)
    }
  }

  // MARK: - Helpers

  private func markdownAttributedString(from text: String) -> AttributedString {
    do {
      return try AttributedString(
        markdown: text,
        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
      )
    } catch {
      return AttributedString(text)
    }
  }

  // MARK: - Actions

  private func retryExplanation() {
    generationTask?.cancel()
    translation = ""
    explanation = ""
    phrases = []
    idioms = []
    generationTask = Task {
      await generateExplanation()
    }
  }

  private func generateExplanation() async {
    guard !Task.isCancelled else { return }

    let availability = service.checkAvailability()

    guard case .available = availability else {
      if case .unavailable(let reason) = availability {
        service.state = .error(reason.localizedDescription)
      }
      return
    }

    do {
      let response = try await service.generateStructuredExplanation(
        text: text,
        context: context
      )

      guard !Task.isCancelled else { return }

      translation = response.translation
      explanation = response.explanation
      phrases = response.phrases
      idioms = response.idioms
    } catch {
      guard !Task.isCancelled else { return }
      // Error is handled by the service
    }
  }
}

// MARK: - Preview

#Preview("In List") {
  @Previewable @State var geminiURL: URL?
  List {
    Section {
      Text("serendipity")
        .font(.body)
    } header: {
      Label("Selected Text", systemImage: "text.quote")
        .textCase(nil)
    }

    WordExplanationView(
      service: .init(),
      text: "serendipity",
      context: "It was pure serendipity that we met.",
      geminiURL: $geminiURL
    )
  }
  .listStyle(.insetGrouped)
}
