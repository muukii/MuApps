#if DEBUG && os(iOS)
  @_spi(Advanced) import SwiftUIIntrospect
  import SwiftUI
  import UIKit

  /// Interactive preview for UIKit's directional lock on a bidirectional SwiftUI scroll view.
  private struct DirectionalLockScrollPreview: View {

    var body: some View {
      ScrollView([.horizontal, .vertical]) {
        DirectionalLockTestCanvas()
      }
      .introspect(.scrollView, on: .iOS(.v26...)) { scrollView in
        scrollView.isDirectionalLockEnabled = true
      }
      .overlay(alignment: .topLeading) {
        Text("Direction Lock On")
          .font(.caption.weight(.semibold))
          .padding(.horizontal, 10)
          .padding(.vertical, 6)
          .background(.regularMaterial, in: Capsule())
          .padding(12)
          .allowsHitTesting(false)
      }
    }
  }

  /// Large coordinate grid that makes horizontal, vertical, and diagonal movement visible.
  private struct DirectionalLockTestCanvas: View {

    private let tileLength: CGFloat = 96
    private let canvasSize = CGSize(width: 960, height: 1_344)

    var body: some View {
      Canvas { context, size in
        let columnCount = Int(size.width / tileLength)
        let rowCount = Int(size.height / tileLength)

        for row in 0..<rowCount {
          for column in 0..<columnCount {
            let rect = CGRect(
              x: CGFloat(column) * tileLength,
              y: CGFloat(row) * tileLength,
              width: tileLength,
              height: tileLength
            )
            let isEvenTile = (row + column).isMultiple(of: 2)
            let fillColor =
              isEvenTile
              ? Color.blue.opacity(0.13)
              : Color.orange.opacity(0.13)

            context.fill(Path(rect), with: .color(fillColor))
            context.stroke(
              Path(rect),
              with: .color(.secondary.opacity(0.22)),
              lineWidth: 1
            )
            context.draw(
              Text("\(column), \(row)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary),
              at: CGPoint(x: rect.midX, y: rect.midY)
            )
          }
        }
      }
      .frame(width: canvasSize.width, height: canvasSize.height)
      .background(Color(uiColor: .systemBackground))
    }
  }

  #Preview("Two-Axis Direction Lock") {
    DirectionalLockScrollPreview()
  }
#endif
