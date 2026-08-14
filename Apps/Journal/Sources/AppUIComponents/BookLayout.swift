import SwiftUI

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
          TreeDisplay(root: node) {
            Cell(value: $0)
          }
        }
      }
    }
  }

  struct Cell: View {

    let value: String

    var body: some View {
      Text(value)
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

/// Recursively places tree nodes without owning a scroll container.
///
/// ``TreeDisplay`` supplies the horizontal viewport around this layout. Keeping
/// recursion scroll-neutral also lets callers reuse the layout in another tree
/// presentation without changing node identity or indentation.
public struct TreeLayout<Node: TreeNode, Cell: View>: View {

  private let nodes: [Node]
  private let indentation: CGFloat
  private let spacing: CGFloat?
  private let cell: (Node.Body) -> Cell

  public init(
    nodes: [Node],
    indentation: CGFloat = 20,
    spacing: CGFloat? = nil,
    @ViewBuilder cell: @escaping (Node.Body) -> Cell
  ) {
    self.nodes = nodes
    self.indentation = indentation
    self.spacing = spacing
    self.cell = cell
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: spacing) {
      ForEach(nodes) { node in
        TreeNodeLayout(
          node: node,
          indentation: indentation,
          spacing: spacing,
          cell: cell
        )
      }
    }
    .padding(.leading, indentation)
  }

  private struct TreeNodeLayout: View {

    let node: Node
    let indentation: CGFloat
    let spacing: CGFloat?
    let cell: (Node.Body) -> Cell

    var body: some View {
      VStack(alignment: .leading, spacing: spacing) {
        TreeStickyContainer(dimsWhenPinned: true) {
          cell(node.body)
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
  private let cell: (Node.Body) -> Cell

  public init(
    root: Node,
    indentation: CGFloat = 20,
    spacing: CGFloat? = nil,
    @ViewBuilder cell: @escaping (Node.Body) -> Cell
  ) {
    self.root = root
    self.indentation = indentation
    self.spacing = spacing
    self.scrollTargetID = nil
    self.verticalProxy = nil
    self.onScrollTargetResolved = { _ in }
    self.cell = cell
  }

  fileprivate init(
    root: Node,
    indentation: CGFloat,
    spacing: CGFloat?,
    scrollTargetID: Node.ID?,
    verticalProxy: ScrollViewProxy,
    onScrollTargetResolved: @escaping @MainActor (Node.ID) -> Void,
    @ViewBuilder cell: @escaping (Node.Body) -> Cell
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
      cell(root.body)
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
    let cell: (Node.Body) -> Cell

    var body: some View {
      ScrollViewReader { horizontalProxy in
        ScrollView(.horizontal) {
          TreeLayout(
            nodes: nodes,
            indentation: indentation,
            spacing: spacing,
            cell: cell
          )
        }
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
  private let cell: (Node.Body) -> Cell

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
      .padding(.leading, offset)
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
