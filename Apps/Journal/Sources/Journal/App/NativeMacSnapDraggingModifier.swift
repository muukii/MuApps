#if os(macOS)
import SwiftUI

/// Native SwiftUI drag behavior used on macOS in place of the UIKit-only snap
/// dragging package. It preserves the package call shape used by Book surfaces
/// while using macOS pointer gestures directly.
struct SnapDraggingModifier: ViewModifier {

  /// Gesture installation mode supported by the current Journal call sites.
  enum GestureMode {
    case simultaneous
  }

  /// Threshold before pointer movement begins updating the surface.
  struct Activation {
    let minimumDistance: Double

    init(minimumDistance: Double = 0) {
      self.minimumDistance = minimumDistance
    }
  }

  /// Rubber-band limits for one axis.
  struct Boundary {
    let min: Double
    let max: Double
    let bandLength: Double

    init(min: Double, max: Double, bandLength: Double) {
      self.min = min
      self.max = max
      self.bandLength = bandLength
    }

    static let infinity = Boundary(
      min: -Double.greatestFiniteMagnitude,
      max: Double.greatestFiniteMagnitude,
      bandLength: 0
    )
  }

  /// Spring values used when settling at the handler's target offset.
  enum SpringParameter {
    case interpolation(mass: Double, stiffness: Double, damping: Double)

    static let hard = SpringParameter.interpolation(
      mass: 1,
      stiffness: 200,
      damping: 20
    )
  }

  /// Callbacks surrounding one pointer drag.
  struct Handler {
    let onStartDragging: () -> Void
    let onEndDragging: (
      _ velocity: inout CGVector,
      _ offset: CGSize,
      _ contentSize: CGSize
    ) -> CGSize

    init(
      onStartDragging: @escaping () -> Void = {},
      onEndDragging: @escaping (
        _ velocity: inout CGVector,
        _ offset: CGSize,
        _ contentSize: CGSize
      ) -> CGSize = { _, _, _ in .zero }
    ) {
      self.onStartDragging = onStartDragging
      self.onEndDragging = onEndDragging
    }
  }

  @Binding private var offset: CGSize
  @State private var initialOffset: CGSize?
  @State private var contentSize: CGSize = .zero

  private let gestureMode: GestureMode
  private let activation: Activation
  private let axis: Axis.Set
  private let horizontalBoundary: Boundary
  private let verticalBoundary: Boundary
  private let springParameter: SpringParameter
  private let handler: Handler

  init(
    gestureMode: GestureMode,
    offset: Binding<CGSize>,
    activation: Activation = .init(),
    axis: Axis.Set = [.horizontal, .vertical],
    horizontalBoundary: Boundary = .infinity,
    verticalBoundary: Boundary = .infinity,
    springParameter: SpringParameter = .hard,
    handler: Handler = .init()
  ) {
    self.gestureMode = gestureMode
    self._offset = offset
    self.activation = activation
    self.axis = axis
    self.horizontalBoundary = horizontalBoundary
    self.verticalBoundary = verticalBoundary
    self.springParameter = springParameter
    self.handler = handler
  }

  func body(content: Content) -> some View {
    content
      .onGeometryChange(for: CGSize.self) { proxy in
        proxy.size
      } action: { size in
        contentSize = size
      }
      .simultaneousGesture(dragGesture)
  }

  private var dragGesture: some Gesture {
    DragGesture(minimumDistance: activation.minimumDistance)
      .onChanged { value in
        if initialOffset == nil {
          initialOffset = offset
          handler.onStartDragging()
        }

        let origin = initialOffset ?? offset
        let proposed = CGSize(
          width: axis.contains(.horizontal)
            ? origin.width + value.translation.width
            : origin.width,
          height: axis.contains(.vertical)
            ? origin.height + value.translation.height
            : origin.height
        )
        offset = CGSize(
          width: rubberBanded(proposed.width, boundary: horizontalBoundary),
          height: rubberBanded(proposed.height, boundary: verticalBoundary)
        )
      }
      .onEnded { value in
        var velocity = CGVector(
          dx: value.predictedEndTranslation.width - value.translation.width,
          dy: value.predictedEndTranslation.height - value.translation.height
        )
        let target = handler.onEndDragging(&velocity, offset, contentSize)
        initialOffset = nil
        withAnimation(settlingAnimation) {
          offset = target
        }
      }
  }

  private var settlingAnimation: Animation {
    switch springParameter {
    case .interpolation(let mass, let stiffness, let damping):
      .interpolatingSpring(mass: mass, stiffness: stiffness, damping: damping)
    }
  }

  private func rubberBanded(_ value: Double, boundary: Boundary) -> Double {
    if value < boundary.min {
      return boundary.min - resistance(boundary.min - value, length: boundary.bandLength)
    }
    if value > boundary.max {
      return boundary.max + resistance(value - boundary.max, length: boundary.bandLength)
    }
    return value
  }

  private func resistance(_ distance: Double, length: Double) -> Double {
    guard length > 0 else { return 0 }
    return length * distance / (length + distance)
  }
}
#endif
