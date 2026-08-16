import SwiftUI

/// A recursively nested value rendered by the tree presentation components.
///
/// Identity belongs to the node's placement in the tree. Callers that can show
/// the same content in multiple branches should therefore use a placement id,
/// not the content object's id.
public protocol TreeNode: Identifiable {

  associatedtype Body

  var body: Body { get }
  var children: [Self] { get }

}

/// Layout information for the tree node currently being rendered.
///
/// The context describes the node's semantic position in the supplied tree,
/// independently from the visual treatment chosen by the cell.
public struct TreeLayoutContext: Equatable, Sendable {

  /// The zero-based indentation depth of the node.
  ///
  /// A tree root or a top-level node supplied directly to ``TreeLayout`` has
  /// a depth of `0`. Each generation of descendants increments the value by
  /// one.
  public let indentationDepth: Int

  fileprivate init(indentationDepth: Int) {
    self.indentationDepth = indentationDepth
  }
}

/// Recursively places tree nodes without owning a scroll container.
///
/// The layout supplies each cell's semantic depth through
/// ``TreeLayoutContext``. The cell owns its visual treatment, so every
/// generation participates in the same finite width proposed by the parent.
public struct TreeLayout<Node: TreeNode, Cell: View>: View {

  private let nodes: [Node]
  private let spacing: CGFloat?
  private let initialIndentationDepth: Int
  private let cell: (Node.Body, TreeLayoutContext) -> Cell

  public init(
    nodes: [Node],
    spacing: CGFloat? = nil,
    @ViewBuilder cell: @escaping (Node.Body) -> Cell
  ) {
    self.init(
      nodes: nodes,
      spacing: spacing,
      initialIndentationDepth: 0
    ) { body, _ in
      cell(body)
    }
  }

  /// Creates a tree layout whose cells receive their current indentation depth.
  public init(
    nodes: [Node],
    spacing: CGFloat? = nil,
    @ViewBuilder cell: @escaping (Node.Body, TreeLayoutContext) -> Cell
  ) {
    self.init(
      nodes: nodes,
      spacing: spacing,
      initialIndentationDepth: 0,
      cell: cell
    )
  }

  fileprivate init(
    nodes: [Node],
    spacing: CGFloat?,
    initialIndentationDepth: Int,
    @ViewBuilder cell: @escaping (Node.Body, TreeLayoutContext) -> Cell
  ) {
    self.nodes = nodes
    self.spacing = spacing
    self.initialIndentationDepth = initialIndentationDepth
    self.cell = cell
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: spacing) {
      ForEach(nodes) { node in
        TreeNodeLayout(
          node: node,
          spacing: spacing,
          indentationDepth: initialIndentationDepth,
          cell: cell
        )
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private struct TreeNodeLayout: View {

    let node: Node
    let spacing: CGFloat?
    let indentationDepth: Int
    let cell: (Node.Body, TreeLayoutContext) -> Cell

    var body: some View {
      VStack(alignment: .leading, spacing: spacing) {
        cell(
          node.body,
          TreeLayoutContext(indentationDepth: indentationDepth)
        )
        .id(node.id)

        if node.children.isEmpty == false {
          TreeLayout(
            nodes: node.children,
            spacing: spacing,
            initialIndentationDepth: indentationDepth + 1,
            cell: cell
          )
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

}

/// Displays one root tree without owning its surrounding vertical scroll view.
///
/// The root and descendants participate directly in the caller's proposed
/// width. A screen can therefore place maps, headers, and other content before
/// or after the tree while cells use their depth context declaratively.
public struct TreeDisplay<Node: TreeNode, Cell: View>: View {

  private let root: Node
  private let spacing: CGFloat?
  private let cell: (Node.Body, TreeLayoutContext) -> Cell

  public init(
    root: Node,
    spacing: CGFloat? = nil,
    @ViewBuilder cell: @escaping (Node.Body) -> Cell
  ) {
    self.init(root: root, spacing: spacing) { body, _ in
      cell(body)
    }
  }

  /// Creates a tree display whose cells receive their current indentation depth.
  public init(
    root: Node,
    spacing: CGFloat? = nil,
    @ViewBuilder cell: @escaping (Node.Body, TreeLayoutContext) -> Cell
  ) {
    self.root = root
    self.spacing = spacing
    self.cell = cell
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: spacing) {
      cell(
        root.body,
        TreeLayoutContext(indentationDepth: 0)
      )
      .id(root.id)

      if root.children.isEmpty == false {
        TreeLayout(
          nodes: root.children,
          spacing: spacing,
          initialIndentationDepth: 1,
          cell: cell
        )
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

#if DEBUG

  private struct _Book: View {

    struct Node: TreeNode {

      let id: UUID

      let body: String

      let children: [Node]

      init(body: String, children: [Node]) {
        self.id = .init()
        self.body = body
        self.children = children
      }
    }

    let nodes: [Node]

    var body: some View {
      ScrollView(.vertical) {
        LazyVStack {
          ForEach(nodes) { node in
            TreeDisplay(root: node) { value, context in
              Cell(
                value: value,
                indentationDepth: context.indentationDepth
              )
            }
          }
        }
      }
    }

    struct Cell: View {

      let value: String
      let indentationDepth: Int

      var body: some View {
        Text("\(value) · depth \(indentationDepth)")
          .padding(.leading, indentationDepth > 0 ? 16 : 0)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding()
          .background(
            RoundedRectangle(cornerRadius: 10)
              .foregroundStyle(.secondary)
          )
      }
    }
  }

  #Preview("Layout") {
    _Book(nodes: [
      .init(
        body: "A",
        children: [
          .init(
            body: "A",
            children: [
              .init(
                body: "A",
                children: [
                  .init(
                    body: "A",
                    children: [
                      .init(
                        body: "A",
                        children: [
                          .init(
                            body: "A",
                            children: [
                              .init(body: "A", children: [])
                            ]
                          )
                        ])
                    ]
                  )
                ])
            ]
          ),
          .init(
            body: "A",
            children: [
              .init(body: "A", children: [])
            ]
          ),
        ]
      ),
      .init(
        body: "A",
        children: [
          .init(
            body: "A",
            children: [
              .init(body: "A", children: [])
            ]
          )
        ]
      ),
    ])
  }

#endif
