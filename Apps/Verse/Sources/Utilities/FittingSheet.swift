import SwiftUI

/**
 https://github.com/BenRiceM/AdaptiveSheet
 */

struct SheetSupportModifier<SheetContent: View, Item: Identifiable>:
  ViewModifier
{

  private enum Mode {
    case flag(Binding<Bool>, () -> SheetContent)
    case item(Binding<Item?>, (Item) -> SheetContent)
  }

  @State var contentHeight: CGFloat?
  private let onDismiss: (() -> Void)?
  private let mode: Mode

  init(
    isPresented: Binding<Bool>,
    onDismiss: (() -> Void)? = nil,
    @ViewBuilder content: @escaping () -> SheetContent
  ) where Item == Never {
    self.onDismiss = onDismiss
    self.mode = .flag(isPresented, content)
  }

  init(
    item: Binding<Item?>,
    onDismiss: (() -> Void)? = nil,
    @ViewBuilder content: @escaping (Item) -> SheetContent
  ) where Item: Identifiable, Content: View {

    self.onDismiss = onDismiss
    self.mode = .item(item, content)
  }

  func body(content: Content) -> some View {

    switch mode {
    case .flag(let isPresented, let sheetContent):
      content
        .sheet(isPresented: isPresented) {
          makeSheetModifiedContent(sheetContent())
        }
    case .item(let item, let sheetContent):
      content
        .sheet(
          item: item,
          onDismiss: onDismiss,
          content: { item in
            makeSheetModifiedContent(sheetContent(item))
          }
        )
    }

  }

  private func makeSheetModifiedContent<_C: View>(_ view: _C) -> some View {

    VStack {
      view
        .frame(maxWidth: .infinity)
        .onGeometryChange(
          for: CGFloat.self,
          of: { $0.size.height },
          action: { height in
            contentHeight = height
          }
        )
      Color.clear
    }
    .presentationDragIndicator(.hidden)
    .presentationDetents(
      [
        .height(contentHeight ?? 0.1)
      ],
      selection: .constant(.height(contentHeight ?? 0.1))
    )
    .map {
      if #available(iOS 16.4, *) {
        if #unavailable(iOS 26.0) {
          $0
            .presentationCornerRadius(20)
        } else {
          $0
        }
      }
    }
  }
}

private struct _SizingLayout: Layout {

  func sizeThatFits(
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout ()
  ) -> CGSize {

    var currentSize: CGSize = .zero

    for subview in subviews {
      let subviewSize = subview.sizeThatFits(proposal)
      currentSize.width = max(currentSize.width, subviewSize.width)
      currentSize.height = max(currentSize.height, subviewSize.height)
    }

    print(currentSize)

    return currentSize
  }

  func placeSubviews(
    in bounds: CGRect,
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout ()
  ) {

    for subview in subviews {
      let subviewSize = subview.sizeThatFits(proposal)
      let origin = CGPoint(
        x: bounds.minX + (bounds.width - subviewSize.width) / 2,
        y: bounds.minY + (bounds.height - subviewSize.height) / 2
      )
      subview.place(
        at: origin,
        proposal: ProposedViewSize(subviewSize)
      )
    }

  }

}

extension View {

  func map<Projected: View>(
    @ViewBuilder _ transform: (Self) -> Projected
  ) -> Projected {
    transform(self)
  }
}

extension View {

  public func fittingSheet<Content: View>(
    isPresented: Binding<Bool>,
    onDismiss: (() -> Void)? = nil,
    @ViewBuilder content: @escaping () -> Content
  ) -> some View {
    modifier(
      SheetSupportModifier(
        isPresented: isPresented,
        onDismiss: onDismiss,
        content: content
      )
    )
  }

  public func fittingSheet<Content: View, Item: Identifiable>(
    item: Binding<Item?>,
    onDismiss: (() -> Void)? = nil,
    @ViewBuilder content: @escaping (Item) -> Content
  ) -> some View {
    modifier(
      SheetSupportModifier(
        item: item,
        onDismiss: onDismiss,
        content: content
      )
    )
  }

}

#Preview {

  struct ContentView: View {

    @State private var isPresented = false

    var body: some View {
      Button("Show Sheet") {
        isPresented.toggle()
      }
      .fittingSheet(isPresented: $isPresented) {
        Text("😀")
          .padding()
      }

    }
  }

  return ContentView()
}

#Preview("Item Sheet") {
  struct PreviewItem: Identifiable {
    let id = UUID()
    let title: String
  }

  struct ContentView: View {
    @State private var selectedItem: PreviewItem?

    var body: some View {
      VStack {
        Button("Show 1") {
          selectedItem = PreviewItem(title: "1アイテム")
        }
        Button("Show 2") {
          selectedItem = PreviewItem(title: "2")
        }
      }
      .fittingSheet(item: $selectedItem) { item in
        VStack {
          Text(item.title)
            .font(.headline)
          Text("ID: \(item.id)")
            .font(.caption)
        }
        .padding()
      }
    }
  }

  return ContentView()
}

#Preview("ScrollView Sheet") {
  struct ContentView: View {
    @State private var isPresented = false

    var body: some View {
      Button("Show ScrollView Sheet") {
        isPresented.toggle()
      }
      .fittingSheet(isPresented: $isPresented) {
        VStack(spacing: 0) {
          Text("Scrollable Content")
            .font(.headline)
            .padding()

          ScrollView {
            LazyVStack(spacing: 12) {
              ForEach(0..<20, id: \.self) { index in
                HStack {
                  Image(systemName: "star.fill")
                    .foregroundStyle(.yellow)
                  Text("Item \(index + 1)")
                  Spacer()
                  Text("Detail")
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color.gray.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
              }
            }
            .padding(.horizontal)
          }
          //          .frame(maxHeight: 300)
        }
        .padding(.bottom)
      }
    }
  }

  return ContentView()
}
