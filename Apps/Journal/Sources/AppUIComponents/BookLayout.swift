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
    TreeDisplay(nodes: nodes, cell: {
      Cell(value: $0)
    })
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

protocol TreeNode: Identifiable {
  
  associatedtype Body
  associatedtype ID
  
  var id: ID { get }
  var body: Body { get }
  var children: [Self] { get }
  
}

struct TreeDisplay<Node: TreeNode, Cell: View>: View {
  
  let nodes: [Node]
  
  let cell: (Node.Body) -> Cell
  
  init(
    nodes: [Node],
    @ViewBuilder cell: @escaping (Node.Body) -> Cell
  ) {
    self.nodes = nodes
    self.cell = cell
  }
  
  var body: some View {

    ScrollView(.vertical) {
      LazyVStack(alignment: .leading) {
        ForEach(nodes) { node in
          cell(node.body)
          ScrollView(.horizontal) {             
            SubDisplay(
              nodes: node.children,
              depth: 0,
              cell: cell
            )
          }
        }
      }
    }

  }

  struct SubDisplay: View {

    let nodes: [Node]
    let depth: Int
    let cell: (Node.Body) -> Cell

    var body: some View {      
      ForEach(nodes) { node in
        
        StickyContainer {
          cell(node.body)
        }
         
        SubDisplay(
          nodes: node.children,
          depth: depth + 1,
          cell: cell          
        )
      }
      .padding(.leading, 20)
    }
  }
  
  struct StickyContainer<Content: View>: View {
    
    let content: Content
    @State var offset: CGFloat = 0
    
    init(@ViewBuilder content: () -> Content) {
      self.content = content()
    }
    
    var hasReached: Bool {
      offset > 0
    }
    
    var body: some View {
      content   
        .opacity(hasReached ? 0.8 : 1)
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
              }) { newValue in
                offset = newValue
            }
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
            .init(body: "A", children: [
              .init(
                body: "A",
                children: [
                  .init(body: "A", children: [
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
        )
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
