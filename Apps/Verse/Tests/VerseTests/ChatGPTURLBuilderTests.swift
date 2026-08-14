import Foundation
import Testing

@testable import Verse

@Suite("ChatGPT URL builder")
struct ChatGPTURLBuilderTests {
  @Test
  @MainActor
  func buildsTemporaryChatURLWithEncodedPrompt() throws {
    let prompt = "Explain 'under the weather' in Japanese & English."
    let url = try #require(ChatGPTURLBuilder.buildURL(prompt: prompt))
    let components = try #require(
      URLComponents(url: url, resolvingAgainstBaseURL: false)
    )

    #expect(components.scheme == "https")
    #expect(components.host == "chatgpt.com")
    #expect(components.path == "/")
    #expect(components.queryItems?.count == 2)
    #expect(components.queryItems?.first(where: { $0.name == "q" })?.value == prompt)
    #expect(
      components.queryItems?.first(where: { $0.name == "temporary-chat" })?.value
        == "true"
    )
  }

  @Test
  @MainActor
  func carriesRenderedExplanationPromptVerbatim() throws {
    let target = "the {context} parameter & its value"
    let context = ">>> the {context} parameter & its value <<<"
    let url = try #require(ChatGPTURLBuilder.buildURL(text: target, context: context))
    let components = try #require(
      URLComponents(url: url, resolvingAgainstBaseURL: false)
    )
    let prompt = try #require(
      components.queryItems?.first(where: { $0.name == "q" })?.value
    )
    let request = try decodeRequest(from: prompt)

    #expect(prompt.hasPrefix("<SystemInstruction>\n"))
    #expect(prompt.hasSuffix("\n</UserPrompt>"))
    #expect(request.schema == "verse.explanation.request.v1")
    #expect(request.target == target)
    #expect(request.context == context)
    #expect(
      components.queryItems?.first(where: { $0.name == "temporary-chat" })?.value
        == "true"
    )
  }

  @MainActor
  private func decodeRequest(from prompt: String) throws -> ExplanationPrompt.Request {
    let prefix = "<Request format=\"json\">\n"
    let suffix = "\n</Request>"
    let prefixRange = try #require(prompt.range(of: prefix))
    let suffixRange = try #require(prompt.range(of: suffix))
    let requestJSON = String(prompt[prefixRange.upperBound..<suffixRange.lowerBound])

    return try JSONDecoder().decode(
      ExplanationPrompt.Request.self,
      from: Data(requestJSON.utf8)
    )
  }
}
