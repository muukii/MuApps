import JournalVault
import Testing

@testable import Tinycurve

/// Characterizes the modality boundary owned by the inline creation composer.
@Suite("Thread draft composer input")
@MainActor
struct ThreadDraftComposerInputTests {

  @Test(
    "Promotes a complete initial web URL to Link",
    arguments: [
      "https://example.com/articles/one",
      "example.com/articles/one",
    ]
  )
  func promotesCompleteInitialWebURL(input: String) {
    let draft = ThreadDraftCard()

    draft.composerText = input

    #expect(draft.kind == .link)
    #expect(draft.text == input)
    #expect(draft.linkURL != nil)
  }

  @Test("Keeps a URL added after existing text as Text")
  func keepsURLAddedAfterText() {
    let draft = ThreadDraftCard()

    draft.composerText = "Read this: "
    draft.composerText = "Read this: https://example.com/articles/one"

    #expect(draft.kind == .text)
    #expect(draft.text == "Read this: https://example.com/articles/one")
  }

  @Test("Keeps an incrementally typed URL as Text")
  func keepsIncrementallyTypedURLAsText() {
    let draft = ThreadDraftCard()
    let input = "https://example.com"

    for index in input.indices {
      draft.composerText = String(input[...index])
    }

    #expect(draft.kind == .text)
    #expect(draft.text == input)
  }

  @Test("Existing whitespace counts as text input")
  func keepsURLAfterWhitespaceAsText() {
    let draft = ThreadDraftCard()

    draft.composerText = " "
    draft.composerText = " https://example.com"

    #expect(draft.kind == .text)
    #expect(draft.text == " https://example.com")
  }

  @Test(
    "Does not promote non-web first values",
    arguments: [
      "hello",
      "user@example.com",
      "https://example.com and a note",
    ]
  )
  func keepsNonWebFirstValueAsText(input: String) {
    let draft = ThreadDraftCard()

    draft.composerText = input

    #expect(draft.kind == .text)
    #expect(draft.text == input)
  }
}
