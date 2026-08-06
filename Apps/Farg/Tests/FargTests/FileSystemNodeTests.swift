import Testing

@testable import Farg

@Suite("File system node debugging")
@MainActor
struct FileSystemNodeTests {

  @Test
  func debugDescriptionShowsTheFullHierarchy() {
    let node: FileSystemNode<String> = .directory(
      .init(
        id: "root",
        name: "LUTs",
        contents: [
          .file(id: "direct", value: "Direct"),
          .directory(
            .init(
              id: "root:Looks",
              name: "Looks",
              contents: [
                .file(id: "cinematic", value: "Cinematic")
              ]
            )
          ),
          .directory(
            .init(
              id: "empty",
              name: "Empty",
              contents: []
            )
          ),
        ]
      )
    )

    #expect(
      node.debugDescription.split(separator: "\n").map(String.init)
        == [
          "directory(name: \"LUTs\", id: \"root\") {",
          "  file(id: \"direct\", value: \"Direct\")",
          "  directory(name: \"Looks\", id: \"root:Looks\") {",
          "    file(id: \"cinematic\", value: \"Cinematic\")",
          "  }",
          "  directory(name: \"Empty\", id: \"empty\", contents: [])",
          "}",
        ]
    )
  }

  @Test
  func foldersComeBeforeFilesAtEveryLevel() {
    let items: [FileSystemNode<String>] = [
      .file(id: "root-file", value: "Root file"),
      .directory(
        .init(
          id: "root-folder",
          name: "Root folder",
          contents: [
            .file(id: "nested-file", value: "Nested file"),
            .directory(
              .init(id: "nested-folder", name: "Nested folder", contents: [])
            ),
          ]
        )
      ),
    ]

    let root = FileSystemNode<String>.ordered(items)
    let nested =
      root.compactMap { item -> [FileSystemNode<String>]? in
        guard case .directory(let directory) = item else { return nil }
        return FileSystemNode<String>.ordered(directory.contents)
      }.first ?? []

    #expect(root.map(\.stableID) == ["directory:root-folder", "file:root-file"])
    #expect(
      nested.map(\.stableID)
        == ["directory:nested-folder", "file:nested-file"]
    )
  }

  @Test
  func explicitIDsDoNotDependOnRecursiveContent() {
    let first: FileSystemNode<String> = .directory(
      .init(
        id: "folder",
        name: "Looks",
        contents: [.file(id: "lut", value: "Before")]
      )
    )
    let second: FileSystemNode<String> = .directory(
      .init(
        id: "folder",
        name: "Looks renamed",
        contents: [
          .file(id: "lut", value: "After"),
          .file(id: "new", value: "New"),
        ]
      )
    )

    #expect(first.stableID == second.stableID)

    let firstFileID: String?
    if case .directory(let directory) = first {
      firstFileID = directory.contents.first?.stableID
    } else {
      firstFileID = nil
    }

    let secondFileID: String?
    if case .directory(let directory) = second {
      secondFileID = directory.contents.first?.stableID
    } else {
      secondFileID = nil
    }

    #expect(firstFileID == "file:lut")
    #expect(secondFileID == "file:lut")
  }
}
