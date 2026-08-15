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
/// independently from the point-based indentation used to draw the layout.
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
/// ``TreeDisplay`` supplies the horizontal viewport around this layout. Keeping
/// recursion scroll-neutral also lets callers reuse the layout in another tree
/// presentation without changing node identity or indentation.
public struct TreeLayout<Node: TreeNode, Cell: View>: View {

  private let nodes: [Node]
  private let indentation: CGFloat
  private let spacing: CGFloat?
  private let initialIndentationDepth: Int
  private let cell: (Node.Body, TreeLayoutContext) -> Cell

  public init(
    nodes: [Node],
    indentation: CGFloat = 20,
    spacing: CGFloat? = nil,
    @ViewBuilder cell: @escaping (Node.Body) -> Cell
  ) {
    self.init(
      nodes: nodes,
      indentation: indentation,
      spacing: spacing,
      initialIndentationDepth: 0
    ) { body, _ in
      cell(body)
    }
  }

  /// Creates a tree layout whose cells receive their current indentation depth.
  public init(
    nodes: [Node],
    indentation: CGFloat = 20,
    spacing: CGFloat? = nil,
    @ViewBuilder cell: @escaping (Node.Body, TreeLayoutContext) -> Cell
  ) {
    self.init(
      nodes: nodes,
      indentation: indentation,
      spacing: spacing,
      initialIndentationDepth: 0,
      cell: cell
    )
  }

  fileprivate init(
    nodes: [Node],
    indentation: CGFloat,
    spacing: CGFloat?,
    initialIndentationDepth: Int,
    @ViewBuilder cell: @escaping (Node.Body, TreeLayoutContext) -> Cell
  ) {
    self.nodes = nodes
    self.indentation = indentation
    self.spacing = spacing
    self.initialIndentationDepth = initialIndentationDepth
    self.cell = cell
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: spacing) {
      ForEach(nodes) { node in
        TreeNodeLayout(
          node: node,
          indentation: indentation,
          spacing: spacing,
          indentationDepth: initialIndentationDepth,
          cell: cell
        )
      }
    }
//    .padding(.leading, indentation)
  }

  private struct TreeNodeLayout: View {

    let node: Node
    let indentation: CGFloat
    let spacing: CGFloat?
    let indentationDepth: Int
    let cell: (Node.Body, TreeLayoutContext) -> Cell

    var body: some View {
      VStack(alignment: .leading, spacing: spacing) {
        TreeStickyContainer(dimsWhenPinned: true) {
          cell(
            node.body,
            TreeLayoutContext(indentationDepth: indentationDepth)
          )
        }
        .id(node.id)
        .anchorPreference(
          key: TreeNodeBoundsPreferenceKey<Node.ID>.self,
          value: .bounds,
          transform: { [node.id: $0] }
        )

        if node.children.isEmpty == false {
          TreeLayout(
            nodes: node.children,
            indentation: indentation,
            spacing: spacing,
            initialIndentationDepth: indentationDepth + 1,
            cell: cell
          )
        }
      }
    }
  }

}

/// Displays one root tree without owning its surrounding vertical scroll view.
///
/// The root participates directly in the caller's layout. Descendant
/// indentation is presented in a horizontal scroll view, so a screen can place
/// maps, headers, and other content declaratively before or after the tree.
public struct TreeDisplay<Node: TreeNode, Cell: View>: View {

  private let root: Node
  private let indentation: CGFloat
  private let spacing: CGFloat?
  private let scrollTargetID: Node.ID?
  private let verticalProxy: ScrollViewProxy?
  private let onScrollTargetResolved: @MainActor (Node.ID) -> Void
  private let cell: (Node.Body, TreeLayoutContext) -> Cell

  /// Creates a tree display whose cells receive their current indentation depth.
  public init(
    root: Node,
    indentation: CGFloat = 20,
    spacing: CGFloat? = nil,
    @ViewBuilder cell: @escaping (Node.Body, TreeLayoutContext) -> Cell
  ) {
    self.init(
      root: root,
      indentation: indentation,
      spacing: spacing,
      scrollTargetID: nil,
      verticalProxy: nil,
      onScrollTargetResolved: { _ in },
      cell: cell
    )
  }

  fileprivate init(
    root: Node,
    indentation: CGFloat,
    spacing: CGFloat?,
    scrollTargetID: Node.ID?,
    verticalProxy: ScrollViewProxy?,
    onScrollTargetResolved: @escaping @MainActor (Node.ID) -> Void,
    @ViewBuilder cell: @escaping (Node.Body, TreeLayoutContext) -> Cell
  ) {
    self.root = root
    self.indentation = indentation
    self.spacing = spacing
    self.scrollTargetID = scrollTargetID
    self.verticalProxy = verticalProxy
    self.onScrollTargetResolved = onScrollTargetResolved
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
        TreeBranch(
          nodes: root.children,
          indentation: indentation,
          spacing: spacing,
          scrollTargetID: scrollTargetID,
          verticalProxy: verticalProxy,
          onScrollTargetResolved: onScrollTargetResolved,
          cell: cell
        )
      }
    }
  }

  /// Presents one root's descendant layout in its own horizontal viewport.
  private struct TreeBranch: View {

    let nodes: [Node]
    let indentation: CGFloat
    let spacing: CGFloat?
    let scrollTargetID: Node.ID?
    let verticalProxy: ScrollViewProxy?
    let onScrollTargetResolved: @MainActor (Node.ID) -> Void
    let cell: (Node.Body, TreeLayoutContext) -> Cell

    var body: some View {
      ScrollViewReader { horizontalProxy in
        ScrollView(.horizontal) {
          TreeLayout(
            nodes: nodes,
            indentation: indentation,
            spacing: spacing,
            initialIndentationDepth: 1,
            cell: cell
          )
        }
        .scrollIndicators(.never)
        .modifier(
          TreeScrollCoordinationModifier(
            targetID: scrollTargetID,
            verticalProxy: verticalProxy,
            horizontalProxy: horizontalProxy,
            onResolved: onScrollTargetResolved
          )
        )
      }
    }
  }
}

/// A standalone vertical scrolling surface for one root tree.
///
/// The root is rendered by ``TreeDisplay``. The outer vertical position stays
/// independent from the horizontal descendant position. Supplying a target id
/// coordinates those existing axes without creating a two-axis scroll view.
public struct TreeScrollView<Node: TreeNode, Cell: View>: View {

  private let root: Node
  private let indentation: CGFloat
  private let spacing: CGFloat?
  private let scrollTargetID: Node.ID?
  private let onScrollTargetResolved: @MainActor (Node.ID) -> Void
  private let cell: (Node.Body, TreeLayoutContext) -> Cell

  public init(
    root: Node,
    indentation: CGFloat = 20,
    spacing: CGFloat? = nil,
    scrollTargetID: Node.ID? = nil,
    onScrollTargetResolved: @escaping @MainActor (Node.ID) -> Void = { _ in },
    @ViewBuilder cell: @escaping (Node.Body) -> Cell
  ) {
    self.root = root
    self.indentation = indentation
    self.spacing = spacing
    self.scrollTargetID = scrollTargetID
    self.onScrollTargetResolved = onScrollTargetResolved
    self.cell = { body, _ in cell(body) }
  }

  /// Creates a scrolling tree whose cells receive their indentation depth.
  public init(
    root: Node,
    indentation: CGFloat = 20,
    spacing: CGFloat? = nil,
    scrollTargetID: Node.ID? = nil,
    onScrollTargetResolved: @escaping @MainActor (Node.ID) -> Void = { _ in },
    @ViewBuilder cell: @escaping (Node.Body, TreeLayoutContext) -> Cell
  ) {
    self.root = root
    self.indentation = indentation
    self.spacing = spacing
    self.scrollTargetID = scrollTargetID
    self.onScrollTargetResolved = onScrollTargetResolved
    self.cell = cell
  }

  public var body: some View {
    ScrollViewReader { verticalProxy in
      ScrollView(.vertical) {
        TreeDisplay(
          root: root,
          indentation: indentation,
          spacing: spacing,
          scrollTargetID: scrollTargetID,
          verticalProxy: verticalProxy,
          onScrollTargetResolved: onScrollTargetResolved,
          cell: cell
        )
      }
      .overlay {
        TreeRootScrollCoordinator(
          targetID: scrollTargetID,
          rootID: root.id,
          verticalProxy: verticalProxy,
          onResolved: onScrollTargetResolved
        )
      }
    }
  }
}

/// Adds coordinated reveal behavior only when a vertical owner is available.
private struct TreeScrollCoordinationModifier<ID: Hashable>: ViewModifier {

  let targetID: ID?
  let verticalProxy: ScrollViewProxy?
  let horizontalProxy: ScrollViewProxy
  let onResolved: @MainActor (ID) -> Void

  @ViewBuilder
  func body(content: Content) -> some View {
    if let verticalProxy {
      content
        .overlayPreferenceValue(
          TreeNodeBoundsPreferenceKey<ID>.self
        ) { nodeBounds in
          if targetID != nil {
            GeometryReader { geometry in
              ZStack(alignment: .topLeading) {
                ForEach(Array(nodeBounds.keys), id: \.self) { nodeID in
                  if let anchor = nodeBounds[nodeID] {
                    let bounds = geometry[anchor]
                    Color.clear
                      .frame(width: 1, height: 1)
                      .position(x: 0, y: bounds.midY)
                      .id(TreeVerticalScrollTargetID(nodeID: nodeID))
                  }
                }

                TreeScrollCoordinator(
                  targetID: targetID,
                  availableNodeIDs: Set(nodeBounds.keys),
                  verticalProxy: verticalProxy,
                  horizontalProxy: horizontalProxy,
                  onResolved: onResolved
                )
              }
            }
            .allowsHitTesting(false)
          }
        }
    } else {
      content
    }
  }
}

/// Resolves a root target that does not require horizontal coordination.
private struct TreeRootScrollCoordinator<ID: Hashable>: View {

  let targetID: ID?
  let rootID: ID
  let verticalProxy: ScrollViewProxy
  let onResolved: @MainActor (ID) -> Void

  @State private var lastResolvedID: ID?

  var body: some View {
    Color.clear
      .frame(width: 0, height: 0)
      .onChange(of: targetID, initial: true) { _, _ in
        resolveTargetIfPossible()
      }
  }

  private func resolveTargetIfPossible() {
    guard let targetID else {
      lastResolvedID = nil
      return
    }
    guard targetID == rootID, lastResolvedID != targetID else {
      return
    }

    lastResolvedID = targetID
    withAnimation(.smooth) {
      verticalProxy.scrollTo(targetID, anchor: .center)
    }
    onResolved(targetID)
  }
}

/// Collects the rendered bounds of every descendant in one horizontal branch.
private struct TreeNodeBoundsPreferenceKey<ID: Hashable>: PreferenceKey {
  static var defaultValue: [ID: Anchor<CGRect>] { [:] }

  static func reduce(
    value: inout [ID: Anchor<CGRect>],
    nextValue: () -> [ID: Anchor<CGRect>]
  ) {
    value.merge(nextValue()) { _, newValue in newValue }
  }
}

/// A node id projected into the outer vertical scroll view's coordinate space.
private struct TreeVerticalScrollTargetID<ID: Hashable>: Hashable {
  let nodeID: ID
}

/// Resolves one pending node after both its layout anchor and scroll views exist.
private struct TreeScrollCoordinator<ID: Hashable>: View {

  let targetID: ID?
  let availableNodeIDs: Set<ID>
  let verticalProxy: ScrollViewProxy
  let horizontalProxy: ScrollViewProxy
  let onResolved: @MainActor (ID) -> Void

  @State private var lastResolvedID: ID?

  var body: some View {
    Color.clear
      .frame(width: 0, height: 0)
      .onChange(of: targetID, initial: true) { _, _ in
        resolveTargetIfPossible()
      }
      .onChange(of: availableNodeIDs) { _, _ in
        resolveTargetIfPossible()
      }
  }

  private func resolveTargetIfPossible() {
    guard let targetID else {
      lastResolvedID = nil
      return
    }
    guard availableNodeIDs.contains(targetID), lastResolvedID != targetID else {
      return
    }

    lastResolvedID = targetID
    withAnimation(.smooth) {
      verticalProxy.scrollTo(
        TreeVerticalScrollTargetID(nodeID: targetID),
        anchor: .center
      )
      horizontalProxy.scrollTo(targetID, anchor: .center)
    }
    onResolved(targetID)
  }
}

/// Keeps a node readable at the leading edge of its nearest scroll viewport.
private struct TreeStickyContainer<Content: View>: View {

  let dimsWhenPinned: Bool
  let content: Content

  @State private var offset: CGFloat = 0

  init(
    dimsWhenPinned: Bool,
    @ViewBuilder content: () -> Content
  ) {
    self.dimsWhenPinned = dimsWhenPinned
    self.content = content()
  }

  private var hasReachedLeadingEdge: Bool {
    offset > 0
  }

  var body: some View {
    content
      .opacity(dimsWhenPinned && hasReachedLeadingEdge ? 0.8 : 1)
//      .padding(.leading, offset)
      .background(
        Color.clear
          .onGeometryChange(
            for: CGFloat.self,
            of: {
              let value = $0.frame(in: .scrollView).minX
              if value < 0 {
                return abs(value)
              } else {
                return 0
              }
            }
          ) { newValue in
            offset = newValue
          }
      )
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
        .frame(
          width: 320,
          alignment: .center
        )
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
