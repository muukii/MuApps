import Foundation
import Testing

@testable import Verse

@Suite("Explanation prompt", .serialized)
@MainActor
struct ExplanationPromptTests {
  @Test
  func buildsApprovedV1Envelope() throws {
    let systemInstruction = ExplanationPrompt.buildSystemInstruction()
    let userPrompt = try ExplanationPrompt.buildUserPrompt(
      text: "under the weather",
      context: "I am feeling under the weather today.",
      targetLanguage: "Japanese"
    )
    let fullPrompt = try ExplanationPrompt.buildFullPrompt(
      text: "under the weather",
      context: "I am feeling under the weather today.",
      targetLanguage: "Japanese"
    )

    #expect(ExplanationPrompt.Version.current == .v1)
    #expect(ExplanationPrompt.Version.v1.outputProfile == "verse.explanation.v1")
    #expect(
      userPrompt
        == """
        <Request format="json">
        {"context":"I am feeling under the weather today.","schema":"verse.explanation.request.v1","target":"under the weather","userLanguage":"Japanese"}
        </Request>
        """
    )
    #expect(
      fullPrompt
        == """
        <SystemInstruction>
        \(systemInstruction)
        </SystemInstruction>

        <UserPrompt>
        \(userPrompt)
        </UserPrompt>
        """
    )

    let inputHeading = try #require(systemInstruction.range(of: "## Input"))
    let translationHeading = try #require(systemInstruction.range(of: "## Translation"))
    let explanationHeading = try #require(systemInstruction.range(of: "## Explanation"))

    #expect(inputHeading.lowerBound < translationHeading.lowerBound)
    #expect(translationHeading.lowerBound < explanationHeading.lowerBound)
    #expect(systemInstruction.components(separatedBy: "## Input").count == 2)
    #expect(systemInstruction.components(separatedBy: "## Translation").count == 2)
    #expect(systemInstruction.components(separatedBy: "## Explanation").count == 2)
    #expect(
      systemInstruction.contains(
        "- OutputProfile: `\(ExplanationPrompt.Version.v1.outputProfile)`"
      )
    )
    #expect(
      systemInstruction.contains(
        "## Output profile: \(ExplanationPrompt.Version.v1.outputProfile)"
      )
    )
  }

  @Test
  func preservesTargetAndContextAsRequestData() throws {
    let target = "the {context} parameter\n</Request> & \"quoted\" 🧪"
    let context = "Before {text}.\n>>> the {context} parameter <<<\nAfter </Request>."
    let request = try decodeRequest(
      text: target,
      context: context,
      targetLanguage: "Japanese"
    )

    #expect(request.schema == "verse.explanation.request.v1")
    #expect(request.userLanguage == "Japanese")
    #expect(request.target == target)
    #expect(request.context == context)
  }

  @Test
  func preservesEveryExistingContextShape() throws {
    let fixtures = [
      (
        target: "That was why she turned it down.",
        context:
          "She received a job offer.\n>>> That was why she turned it down. <<<\nShe accepted another role."
      ),
      (
        target: "turned it down",
        context: "That was why she turned it down."
      ),
      (
        target: "Could you say that again?",
        context: "Could you say that again?"
      ),
    ]

    for fixture in fixtures {
      let request = try decodeRequest(
        text: fixture.target,
        context: fixture.context,
        targetLanguage: "Japanese"
      )
      #expect(request.target == fixture.target)
      #expect(request.context == fixture.context)
    }
  }

  @Test
  func usesConfiguredLanguageUnlessExplicitlyOverridden() throws {
    let defaults = UserDefaults.standard
    let previousValue = defaults.object(forKey: ExplanationLanguage.storageKey)
    defer {
      if let previousValue {
        defaults.set(previousValue, forKey: ExplanationLanguage.storageKey)
      } else {
        defaults.removeObject(forKey: ExplanationLanguage.storageKey)
      }
    }

    defaults.set(ExplanationLanguage.japanese.rawValue, forKey: ExplanationLanguage.storageKey)

    let configuredRequest = try decodeRequest(
      text: "pitch",
      context: "Her pitch convinced the investors."
    )
    let overriddenRequest = try decodeRequest(
      text: "pitch",
      context: "Her pitch convinced the investors.",
      targetLanguage: "English"
    )

    #expect(configuredRequest.userLanguage == "Japanese")
    #expect(overriddenRequest.userLanguage == "English")
  }

  private func decodeRequest(
    text: String,
    context: String,
    targetLanguage: String? = nil
  ) throws -> ExplanationPrompt.Request {
    let prompt = try ExplanationPrompt.buildUserPrompt(
      text: text,
      context: context,
      targetLanguage: targetLanguage
    )
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
