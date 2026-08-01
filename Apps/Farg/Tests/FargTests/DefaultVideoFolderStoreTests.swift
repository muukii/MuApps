import Foundation
import Testing

@testable import Farg

@MainActor
@Suite("Default video folder")
struct DefaultVideoFolderStoreTests {

  @Test
  func loadsPersistedFolderMetadata() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }

    let expected = DefaultVideoFolder(
      displayName: "Camera01",
      volumeName: "LUNA ULTRA",
      volumeUUIDString: "camera-volume",
      bookmarkData: Data([1, 2, 3])
    )
    try JSONEncoder().encode(expected).write(to: fixture.indexURL, options: .atomic)

    let store = DefaultVideoFolderStore(indexURL: fixture.indexURL)

    #expect(store.folder == expected)
  }

  @Test
  func clearingFolderRemovesItsPersistedBookmark() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }

    let persisted = DefaultVideoFolder(
      displayName: "Camera01",
      volumeName: nil,
      volumeUUIDString: nil,
      bookmarkData: Data([1])
    )
    try JSONEncoder().encode(persisted).write(to: fixture.indexURL, options: .atomic)
    let store = DefaultVideoFolderStore(indexURL: fixture.indexURL)

    try store.clearFolder()

    #expect(store.folder == nil)
    #expect(FileManager.default.fileExists(atPath: fixture.indexURL.path) == false)
  }

  @Test
  func missingBookmarkUsesTheSystemFilesLocation() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }

    let store = DefaultVideoFolderStore(indexURL: fixture.indexURL)

    #expect(store.makeAccess() == nil)
  }

  @Test
  func unresolvableBookmarkUsesTheSystemFilesLocation() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }

    let persisted = DefaultVideoFolder(
      displayName: "Disconnected Camera",
      volumeName: "LUNA ULTRA",
      volumeUUIDString: "camera-volume",
      bookmarkData: Data([0, 1, 2, 3])
    )
    try JSONEncoder().encode(persisted).write(to: fixture.indexURL, options: .atomic)
    let store = DefaultVideoFolderStore(indexURL: fixture.indexURL)

    #expect(store.makeAccess() == nil)
  }

  private func makeFixture() throws -> (directory: URL, indexURL: URL) {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "DefaultVideoFolderStoreTests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    return (
      directory,
      directory.appending(path: "default-video-folder.json")
    )
  }
}
