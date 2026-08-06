import SwiftUI

/// A file or directory entry rendered by a horizontal navigation surface.
enum FileSystemNode<Value: Hashable>: Hashable {
  case file(id: String, value: Value)
  case directory(Directory)

  /// A named directory with stable identity and navigable child entries.
  struct Directory: Hashable {
    /// Stable identity used to resolve navigation paths.
    let id: String
    /// The directory name shown to the user.
    let name: String
    /// Files and child directories directly inside this directory.
    let contents: [FileSystemNode<Value>]
  }

  /// An explicit, shallow identity for SwiftUI collection diffing.
  var stableID: String {
    switch self {
    case .file(let id, _):
      return "file:\(id)"
    case .directory(let directory):
      return "directory:\(directory.id)"
    }
  }

  /// Places directories before files while preserving each group order.
  static func ordered(_ items: [Self]) -> [Self] {
    items.filter { item in
      switch item {
      case .directory:
        return true
      case .file:
        return false
      }
    }
      + items.filter { item in
        switch item {
        case .file:
          return true
        case .directory:
          return false
        }
      }
  }

}

extension FileSystemNode: CustomDebugStringConvertible {

  /// A multiline tree representation used by `debugPrint` and LLDB.
  var debugDescription: String {
    makeDebugDescription(indent: "")
  }

  private func makeDebugDescription(indent: String) -> String {
    switch self {
    case .file(let id, let value):
      return "\(indent)file(id: \(String(reflecting: id)), value: \(String(reflecting: value)))"

    case .directory(let directory):
      let header =
        "\(indent)directory("
        + "name: \(String(reflecting: directory.name)), "
        + "id: \(String(reflecting: directory.id))"

      guard directory.contents.isEmpty == false else {
        return "\(header), contents: [])"
      }

      let children = directory.contents
        .map {
          $0.makeDebugDescription(indent: indent + "  ")
        }
        .joined(separator: "\n")
      return "\(header)) {\n\(children)\n\(indent)}"
    }
  }
}

/// Displays files and folders in a horizontally navigable toolbar.
struct HorizontalFolderView<
  Value: Hashable,
  ItemView: View,
  FolderView: View
>: View {

  let items: [FileSystemNode<Value>]
  /// Directory IDs used only to seed the toolbar's initial retained levels.
  let initialPath: [String]

  private let itemView: (Value) -> ItemView
  private let folderView: (String) -> FolderView

  init(
    items: [FileSystemNode<Value>],
    initialPath: [String] = [],
    @ViewBuilder itemView: @escaping (Value) -> ItemView,
    @ViewBuilder folderView: @escaping (String) -> FolderView
  ) {
    self.items = items
    self.initialPath = initialPath
    self.itemView = itemView
    self.folderView = folderView
  }

  var body: some View {
    NavigationToolbar(
      usesGlass: false,
      initialStack: initialStack
    ) {
      ItemsView(
        items: FileSystemNode.ordered(items),
        itemView: itemView,
        folderView: folderView
      )
    }
  }

  /// Resolves the initial directory path into already-open view levels.
  private var initialStack: [AnyView] {
    var currentItems = FileSystemNode.ordered(items)
    var stack: [AnyView] = []

    for folderID in initialPath {
      guard
        let directory = currentItems.compactMap({
          item -> FileSystemNode<Value>.Directory? in
          guard case .directory(let directory) = item else { return nil }
          return directory
        }).first(where: { $0.id == folderID })
      else {
        break
      }

      stack.append(
        AnyView(
          ItemsView(
            items: FileSystemNode.ordered(directory.contents),
            itemView: itemView,
            folderView: folderView
          )
        )
      )
      currentItems = FileSystemNode.ordered(directory.contents)
    }

    return stack
  }

  struct ItemsView: View {

    let items: [FileSystemNode<Value>]
    let itemView: (Value) -> ItemView
    let folderView: (String) -> FolderView

    var body: some View {
      ScrollView(.horizontal, showsIndicators: false) {
        LazyHStack(spacing: 24) {
          ForEach(items, id: \.stableID) { item in
            ItemCell(
              item: item,
              itemView: itemView,
              folderView: folderView
            )
          }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
      }
    }
  }

  struct ItemCell: View {

    @Environment(\.stackedView) private var stackedView
    let item: FileSystemNode<Value>
    let itemView: (Value) -> ItemView
    let folderView: (String) -> FolderView

    var body: some View {
      switch item {
      case .file(_, let value):
        itemView(value)
      case .directory(let directory):
        Button {
          stackedView.wrappedValue.append(
            AnyView(
              ItemsView(
                items: FileSystemNode.ordered(directory.contents),
                itemView: itemView,
                folderView: folderView
              )
            )
          )
        } label: {
          folderView(directory.name)
        }
        .buttonStyle(.plain)
      }
    }
  }
}

#Preview {
  HorizontalFolderView(
    items: [
      .file(id: "A", value: "A"),
      .directory(
        .init(
          id: "Mu",
          name: "Mu",
          contents: [
            .file(id: "1", value: "1"),
            .file(id: "2", value: "2"),
            .file(id: "3", value: "3"),
          ]
        )
      ),
    ],
    itemView: { value in
      VStack {
        Image(systemName: "document.fill")
        Text(value)
      }
    },
    folderView: { name in
      VStack {
        Image(systemName: "folder.fill")
        Text(name)
      }
    }
  )
}
