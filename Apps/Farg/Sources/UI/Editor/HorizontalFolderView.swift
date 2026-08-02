import SwiftUI
/// A file or directory entry rendered by a horizontal navigation surface.
enum FileSystemNode<Value: Hashable>: Hashable {
  case file(value: Value)
  case directory(Directory)

  /// A named directory with stable identity and navigable child entries.
  struct Directory: Hashable {
    /// Stable identity used to resolve an initial navigation path.
    let id: String
    /// The directory name shown to the user.
    let name: String
    /// Files and child directories directly inside this directory.
    let contents: [FileSystemNode<Value>]

    init(
      id: String? = nil,
      name: String,
      contents: [FileSystemNode<Value>]
    ) {
      self.id = id ?? name
      self.name = name
      self.contents = contents
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
  /// Directory IDs to open before presenting the root's current contents.
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
      initialStack: initialStack) {
      ItemsView(
        items: items,
        itemView: itemView,
        folderView: folderView
      )
    }
    .id(initialPath)
  }

  /// Builds the already-open directory levels for an externally selected item.
  private var initialStack: [AnyView] {
    var currentItems = items
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
            items: directory.contents,
            itemView: itemView,
            folderView: folderView
          )
        )
      )
      currentItems = directory.contents
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
          ForEach(items, id: \.self) { item in
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

    @Environment(\.stackedView) var stackedView
    let item: FileSystemNode<Value>
    let itemView: (Value) -> ItemView
    let folderView: (String) -> FolderView

    var body: some View {
      switch item {
      case .file(let value):
        itemView(value)
      case .directory(let directory):
        Button {
          stackedView.wrappedValue.append(
            AnyView(
              ItemsView(
                items: directory.contents,
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

  @Previewable @State var selection: String?

  HorizontalFolderView(
    items: [
      .file(value: "A"),
      .directory(
        .init(
          name: "Mu",
          contents: [
            .file(value: "1"),
            .file(value: "2"),
            .file(value: "3"),
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
