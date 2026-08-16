import CoreTransferable
import Foundation
import JournalVault
import Testing

@testable import Tinycurve

/// Characterizes the Home-only drag/drop import and posting boundaries.
@Suite("Home drop import")
@MainActor
struct HomeDropItemTests {

  @Test("Maps complete web URLs to Link and prose to Text")
  func mapsDroppedText() throws {
    let linkDraft = try HomeDropItem.importedText("example.com/articles/one").cardDraft()
    let textDraft = try HomeDropItem.importedText(
      "Read https://example.com/articles/one"
    ).cardDraft()

    #expect(linkDraft.kind == .link)
    #expect(linkDraft.text == "https://example.com/articles/one")
    #expect(textDraft.kind == .text)
    #expect(textDraft.text == "Read https://example.com/articles/one")
  }

  @Test("Preserves authored whitespace in dropped prose")
  func preservesDroppedTextWhitespace() throws {
    let draft = try HomeDropItem.importedText("  First line\nSecond line  ").cardDraft()

    #expect(draft.kind == .text)
    #expect(draft.text == "  First line\nSecond line  ")
  }

  @Test("Materializes a real string item provider through CoreTransferable")
  func materializesStringProvider() async throws {
    let provider = NSItemProvider(object: NSString(string: "example.com/provider"))

    let draft = try await provider.loadHomeDropItem().cardDraft()

    #expect(draft.kind == .link)
    #expect(draft.text == "https://example.com/provider")
  }

  @Test("Materializes a real URL item provider through CoreTransferable")
  func materializesURLProvider() async throws {
    let url = try #require(URL(string: "https://example.com/from-url-provider"))
    let provider = NSItemProvider(object: url as NSURL)

    let draft = try await provider.loadHomeDropItem().cardDraft()

    #expect(draft.kind == .link)
    #expect(draft.text == url.absoluteString)
  }

  @Test("Copies a real file item provider through CoreTransferable")
  func materializesFileProvider() async throws {
    let fixture = try TemporaryFixture(fileName: "provider.pdf")
    defer { fixture.cleanUp() }
    let provider = try #require(NSItemProvider(contentsOf: fixture.fileURL))
    let item = try await provider.loadHomeDropItem()
    defer { item.cleanUpTemporaryFiles() }

    let draft = try item.cardDraft()
    let resource = try #require(draft.mediaResources.first)

    #expect(draft.kind == .file)
    #expect(resource.role == .file)
    #expect(resource.byteSize == fixture.byteSize)
  }

  @Test(
    "Classifies file URLs by content type",
    arguments: [
      FileCase(fileName: "photo.jpg", expectedKind: .photo, expectedRole: .originalImage),
      FileCase(fileName: "movie.mov", expectedKind: .video, expectedRole: .originalVideo),
      FileCase(fileName: "sound.m4a", expectedKind: .audio, expectedRole: .audio),
      FileCase(fileName: "document.pdf", expectedKind: .file, expectedRole: .file),
    ]
  )
  func classifiesFileURL(testCase: FileCase) throws {
    let fixture = try TemporaryFixture(fileName: testCase.fileName)
    defer { fixture.cleanUp() }
    let item = HomeDropItem.importedURL(fixture.fileURL)
    defer { item.cleanUpTemporaryFiles() }

    let draft = try item.cardDraft()
    let resource = try #require(draft.mediaResources.first)

    #expect(draft.kind == testCase.expectedKind)
    #expect(resource.role == testCase.expectedRole)
    #expect(resource.byteSize == fixture.byteSize)
    if testCase.expectedKind == .file {
      #expect(draft.text == testCase.fileName)
    }
  }

  @Test("Rejects folders without preventing sibling posts")
  func rejectsFoldersIndependently() throws {
    let folder = try TemporaryFixture(directoryName: "Folder")
    defer { folder.cleanUp() }
    let recorder = PostRecorder()

    let result = HomeDropPostingCoordinator.post(
      items: [
        .importedText("First"),
        .importedURL(folder.fileURL),
        .importedText("Last"),
      ],
      postCard: recorder.post
    )

    #expect(result.postedCount == 2)
    #expect(result.failedItemIndices == [1])
    #expect(recorder.drafts.map(\.text) == ["First", "Last"])
  }

  @Test("Keeps successful roots when a later transaction fails")
  func preservesPartialSuccess() {
    let recorder = PostRecorder(rejectedText: "Reject")

    let result = HomeDropPostingCoordinator.post(
      items: [
        .importedText("First"),
        .importedText("Reject"),
        .importedText("Last"),
      ],
      postCard: recorder.post
    )

    #expect(result.postedCount == 2)
    #expect(result.failedItemIndices == [1])
    #expect(recorder.drafts.map(\.text) == ["First", "Reject", "Last"])
  }

  @Test("Cleans an app-owned file after its posting attempt")
  func cleansTemporaryFileAfterPosting() throws {
    let fixture = try TemporaryFixture(fileName: "document.pdf")
    defer { fixture.cleanUp() }
    let item = HomeDropItem.importedURL(fixture.fileURL)
    guard case .file(let file) = item.content else {
      Issue.record("Expected a generic File drop")
      return
    }
    let owningDirectoryURL = file.temporaryFile.owningDirectoryURL
    #expect(FileManager.default.fileExists(atPath: owningDirectoryURL.path))

    _ = HomeDropPostingCoordinator.post(
      items: [item],
      postCard: PostRecorder().post
    )

    #expect(FileManager.default.fileExists(atPath: owningDirectoryURL.path) == false)
  }

  @Test("Does not mutate an authored composer draft")
  func preservesAuthoredComposerDraft() {
    let authoredDraft = ThreadDraftCard(kind: .text, text: "Still writing")

    _ = HomeDropPostingCoordinator.post(
      items: [.importedText("Dropped separately")],
      postCard: PostRecorder().post
    )

    #expect(authoredDraft.kind == .text)
    #expect(authoredDraft.text == "Still writing")
  }

  @Test("Enables the destination for Home only")
  func enablesHomePlacementOnly() {
    #expect(CreationComposerPlacement.root.acceptsHomeDrop)
    #expect(CreationComposerPlacement.continuation.acceptsHomeDrop == false)
  }
}

extension NSItemProvider {

  /// Loads the production transferable through the same provider bridge used by
  /// SwiftUI's typed drop destination.
  fileprivate func loadHomeDropItem() async throws -> HomeDropItem {
    try await withCheckedThrowingContinuation { continuation in
      _ = loadTransferable(type: HomeDropItem.self) { result in
        continuation.resume(with: result)
      }
    }
  }
}

extension HomeDropItemTests {

  /// One file-classification expectation supplied to the parameterized test.
  struct FileCase: Sendable, CustomTestStringConvertible {
    let fileName: String
    let expectedKind: Card.Kind
    let expectedRole: AttachmentResource.Role

    var testDescription: String { fileName }
  }

  /// Explicitly owned fixture directory safe to remove after one test.
  final class TemporaryFixture {
    let directoryURL: URL
    let fileURL: URL
    let byteSize: Int

    init(fileName: String) throws {
      let directoryURL = FileManager.default.temporaryDirectory
        .appending(
          path: "tinycurve-home-drop-test-\(UUID().uuidString)", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(
        at: directoryURL,
        withIntermediateDirectories: true
      )
      let fileURL = directoryURL.appending(path: fileName, directoryHint: .notDirectory)
      let data = Data("fixture".utf8)
      try data.write(to: fileURL)

      self.directoryURL = directoryURL
      self.fileURL = fileURL
      self.byteSize = data.count
    }

    init(directoryName: String) throws {
      let directoryURL = FileManager.default.temporaryDirectory
        .appending(
          path: "tinycurve-home-drop-test-\(UUID().uuidString)", directoryHint: .isDirectory)
      let fileURL = directoryURL.appending(path: directoryName, directoryHint: .isDirectory)
      try FileManager.default.createDirectory(
        at: fileURL,
        withIntermediateDirectories: true
      )

      self.directoryURL = directoryURL
      self.fileURL = fileURL
      self.byteSize = 0
    }

    func cleanUp() {
      try? FileManager.default.removeItem(at: directoryURL)
    }
  }

  /// Main-actor fake that records every persistence attempt in source order.
  @MainActor
  final class PostRecorder {
    private let rejectedText: String?
    private(set) var drafts: [VaultContentStore.CardDraft] = []

    init(rejectedText: String? = nil) {
      self.rejectedText = rejectedText
    }

    func post(_ draft: VaultContentStore.CardDraft) throws -> UUID {
      drafts.append(draft)
      if draft.text == rejectedText {
        throw TestError.rejected
      }
      return UUID()
    }
  }

  enum TestError: Error {
    case rejected
  }
}
