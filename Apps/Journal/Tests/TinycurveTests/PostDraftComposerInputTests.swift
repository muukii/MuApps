import JournalVault
import Testing

@testable import Tinycurve

/// Characterizes the modality boundary owned by the inline creation composer.
@Suite("Post draft composer input")
@MainActor
struct PostDraftComposerInputTests {

  @Test(
    "Promotes a complete initial web URL to Link",
    arguments: [
      "https://example.com/articles/one",
      "example.com/articles/one",
    ]
  )
  func promotesCompleteInitialWebURL(input: String) {
    let draft = CardEditDraft()

    draft.composerText = input

    #expect(draft.kind == .link)
    #expect(draft.text == input)
    #expect(draft.linkURL != nil)
  }

  @Test("Keeps a URL added after existing text as Text")
  func keepsURLAddedAfterText() {
    let draft = CardEditDraft()

    draft.composerText = "Read this: "
    draft.composerText = "Read this: https://example.com/articles/one"

    #expect(draft.kind == .text)
    #expect(draft.text == "Read this: https://example.com/articles/one")
  }

  @Test("Keeps an incrementally typed URL as Text")
  func keepsIncrementallyTypedURLAsText() {
    let draft = CardEditDraft()
    let input = "https://example.com"

    for index in input.indices {
      draft.composerText = String(input[...index])
    }

    #expect(draft.kind == .text)
    #expect(draft.text == input)
  }

  @Test("Existing whitespace counts as text input")
  func keepsURLAfterWhitespaceAsText() {
    let draft = CardEditDraft()

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
    let draft = CardEditDraft()

    draft.composerText = input

    #expect(draft.kind == .text)
    #expect(draft.text == input)
  }

  @Test("Text and Todo mode changes preserve authored body")
  func preservesBodyAcrossComposerModes() {
    let draft = CardEditDraft(text: "Buy coffee")

    draft.setComposerMode(.todo)

    #expect(draft.composerMode == .todo)
    #expect(draft.text == "Buy coffee")
    #expect(draft.completedAt == nil)

    draft.setComposerMode(.text)

    #expect(draft.composerMode == .text)
    #expect(draft.text == "Buy coffee")
    #expect(draft.completedAt == nil)
  }

  @Test("Empty Todo mode is a neutral composer placeholder")
  func treatsEmptyTodoAsComposerPlaceholder() {
    let draft = CardEditDraft(kind: .todo)

    #expect(draft.isEmptyComposerDraft)
    #expect(draft.isEmptyTextDraft == false)
    #expect(draft.canSave == false)
  }

  @Test("A complete initial URL remains Todo while Todo mode is active")
  func keepsCompleteInitialURLAsTodo() {
    let draft = CardEditDraft(kind: .todo)

    draft.composerText = "https://example.com/tasks/one"

    #expect(draft.composerMode == .todo)
    #expect(draft.text == "https://example.com/tasks/one")
    #expect(draft.canSave)
  }
}
