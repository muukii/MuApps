import Observation
import SwiftUI
import UIKit

// MARK: - Value

/// A finished doodle, rendered to a transparent PNG. The host decides whether to
/// persist it.
public struct DoodleDrawing: Sendable, Equatable {
  public var imageData: Data
  public var pixelSize: CGSize

  public init(imageData: Data, pixelSize: CGSize) {
    self.imageData = imageData
    self.pixelSize = pixelSize
  }

  public var image: UIImage? {
    UIImage(data: imageData)
  }
}

// MARK: - Controller

/// Drives a `DoodleCanvasView` from SwiftUI: holds the live brush and forwards
/// undo/clear/export to the underlying Metal view.
@MainActor
@Observable
public final class DoodleCanvas {

  public var brush = InkBrush()

  @ObservationIgnored fileprivate weak var view: DoodleMetalView?

  public init() {}

  public func undo() {
    view?.undo()
  }

  public func clear() {
    view?.clearCanvas()
  }

  /// Renders the current canvas to a PNG. Returns `nil` if nothing is drawn yet.
  public func makeDrawing() -> DoodleDrawing? {
    guard let image = view?.exportImage(), let data = image.pngData() else { return nil }
    let pixelSize = CGSize(
      width: image.size.width * image.scale,
      height: image.size.height * image.scale
    )
    return DoodleDrawing(imageData: data, pixelSize: pixelSize)
  }
}

// MARK: - Canvas View

/// A self-contained Metal doodle surface with a brush color/size toolbar, undo,
/// clear, and (optional) export. Smooth ink via ported Brightroom smoothing.
public struct DoodleCanvasView: View {

  @State private var canvas = DoodleCanvas()
  @State private var color: Color = .black

  private let onExport: (@MainActor @Sendable (DoodleDrawing) -> Void)?

  public init(onExport: (@MainActor @Sendable (DoodleDrawing) -> Void)? = nil) {
    self.onExport = onExport
  }

  public var body: some View {
    ZStack {
      Color(.systemBackground).ignoresSafeArea()

      DoodleCanvasRepresentable(canvas: canvas)
        .ignoresSafeArea()

      VStack {
        Spacer()
        controlBar
          .padding(.horizontal)
          .padding(.bottom, 8)
      }
    }
    .onChange(of: color) { _, newValue in
      canvas.brush.color = newValue.inkColor
    }
  }

  private var controlBar: some View {
    HStack(spacing: 16) {
      ColorPicker("Color", selection: $color, supportsOpacity: false)
        .labelsHidden()

      Slider(
        value: Binding(get: { canvas.brush.size }, set: { canvas.brush.size = $0 }),
        in: 2...48
      )
      .frame(maxWidth: 160)

      Button {
        canvas.undo()
      } label: {
        Image(systemName: "arrow.uturn.backward")
      }

      Button(role: .destructive) {
        canvas.clear()
      } label: {
        Image(systemName: "trash")
      }

      if let onExport {
        Button {
          if let drawing = canvas.makeDrawing() {
            onExport(drawing)
          }
        } label: {
          Image(systemName: "checkmark")
            .fontWeight(.semibold)
        }
      }
    }
    .padding(12)
    .background(.ultraThinMaterial, in: Capsule())
  }
}

// MARK: - UIKit bridge

private struct DoodleCanvasRepresentable: UIViewRepresentable {
  let canvas: DoodleCanvas

  func makeUIView(context: Context) -> DoodleMetalView {
    guard let view = DoodleMetalView.make() else {
      fatalError("Metal is unavailable; cannot create the doodle canvas.")
    }
    view.brush = canvas.brush
    canvas.view = view
    return view
  }

  func updateUIView(_ uiView: DoodleMetalView, context: Context) {
    uiView.brush = canvas.brush
  }
}

// MARK: - Color → InkColor

extension Color {
  fileprivate var inkColor: InkColor {
    let uiColor = UIColor(self)
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alpha: CGFloat = 0
    uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
    return InkColor(red: Double(red), green: Double(green), blue: Double(blue), alpha: Double(alpha))
  }
}
