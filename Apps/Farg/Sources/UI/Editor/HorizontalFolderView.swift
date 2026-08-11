import MuComponents
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
  /// Whether navigation levels use the interactive glass treatment.
  let usesGlass: Bool

  private let itemView: (Value) -> ItemView
  private let folderView: (String) -> FolderView

  init(
    items: [FileSystemNode<Value>],
    initialPath: [String] = [],
    usesGlass: Bool = false,
    @ViewBuilder itemView: @escaping (Value) -> ItemView,
    @ViewBuilder folderView: @escaping (String) -> FolderView
  ) {
    self.items = items
    self.initialPath = initialPath
    self.usesGlass = usesGlass
    self.itemView = itemView
    self.folderView = folderView
  }

  var body: some View {
    NavigationToolbar(
      usesGlass: usesGlass,
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

#if DEBUG

#Preview("Glass") {
  HorizontalFolderPreviewStage(usesGlass: true)
}

#Preview("Without Glass") {
  HorizontalFolderPreviewStage(usesGlass: false)
}

/// A stable file value rendered by the folder-navigation previews.
private struct HorizontalFolderPreviewItem: Hashable {
  let title: String
  let systemImage: String
}

/// Presents the same folder tree and backdrop for both material variants.
private struct HorizontalFolderPreviewStage: View {

  let usesGlass: Bool

  var body: some View {
    ZStack {
      HorizontalFolderPreviewBackdrop()

      HorizontalFolderView(
        items: previewItems,
        usesGlass: usesGlass,
        itemView: { item in
          HorizontalFolderPreviewCell(
            title: item.title,
            systemImage: item.systemImage
          )
        },
        folderView: { name in
          HorizontalFolderPreviewCell(
            title: name,
            systemImage: "folder.fill"
          )
        }
      )
      .padding(.horizontal, 20)
    }
    .frame(height: 220)
    .clipped()
  }

  private var previewItems: [FileSystemNode<HorizontalFolderPreviewItem>] {
    [
      .directory(
        .init(
          id: "favorites",
          name: "Favorites",
          contents: [
            .directory(
              .init(
                id: "archive",
                name: "Archive",
                contents: [
                  .file(
                    id: "classic",
                    value: .init(
                      title: "Classic",
                      systemImage: "camera.filters"
                    )
                  )
                ]
              )
            ),
            .file(
              id: "cinematic",
              value: .init(
                title: "Cinematic",
                systemImage: "film.stack"
              )
            ),
            .file(
              id: "warm",
              value: .init(
                title: "Warm",
                systemImage: "sun.max.fill"
              )
            ),
          ]
        )
      ),
      .file(
        id: "original",
        value: .init(
          title: "Original",
          systemImage: "circle.lefthalf.filled"
        )
      ),
      .file(
        id: "soft",
        value: .init(
          title: "Soft",
          systemImage: "camera.filters"
        )
      ),
    ]
  }
}

/// A colorful surface that makes the glass sampling visible in the canvas.
private struct HorizontalFolderPreviewBackdrop: View {
  var body: some View {
    ZStack {
      LinearGradient(
        colors: [
          Color.indigo,
          Color.blue,
          Color.orange,
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )

      Circle()
        .fill(Color.cyan.opacity(0.8))
        .frame(width: 170, height: 170)
        .blur(radius: 12)
        .offset(x: 150, y: -70)

      Circle()
        .fill(Color.pink.opacity(0.75))
        .frame(width: 150, height: 150)
        .blur(radius: 16)
        .offset(x: -150, y: 90)
    }
  }
}

/// A compact file or folder label shared by both preview variants.
private struct HorizontalFolderPreviewCell: View {

  let title: String
  let systemImage: String

  var body: some View {
    VStack(spacing: 6) {
      Image(systemName: systemImage)
        .font(.title2)

      Text(title)
        .font(.caption.weight(.medium))
        .lineLimit(1)
    }
    .frame(minWidth: 64)
    .foregroundStyle(.white)
  }
}

#endif
