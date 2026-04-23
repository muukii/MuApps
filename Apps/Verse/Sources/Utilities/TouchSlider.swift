//
//  TouchSlider.swift
//  YouTubeSubtitle
//
//  Originally from: https://github.com/FluidGroup/swiftui-touch-slider
//  Copied to remove external dependency
//

import SwiftUI

public struct TouchSlider: View {

  private struct TrackingState: Equatable {
    let beginProgress: Double
  }

  var isTracking: Bool {
    trackingState != nil
  }

  @GestureState private var trackingState: TrackingState? = nil
  @State private var draggingProgress: Double?

  @Binding var progress: Double
  public let speed: Double
  public let direction: Axis
  public let continuous: Bool

  private let foregroundColor: Color
  private let backgroundColor: Color
  private let cornerRadius: Double

  /// The progress value to display (uses dragging value when in non-continuous mode and dragging)
  private var displayProgress: Double {
    if !continuous, let dragging = draggingProgress {
      return dragging
    }
    return progress
  }

  public init(
    direction: Axis,
    value: Binding<Double>,
    speed: Double = 1,
    continuous: Bool = true,
    foregroundColor: Color = Color(white: 0.5, opacity: 0.5),
    backgroundColor: Color = Color(white: 0.5, opacity: 0.5),
    cornerRadius: Double = .greatestFiniteMagnitude
  ) {
    self._progress = value
    self.direction = direction
    self.speed = speed
    self.continuous = continuous
    self.foregroundColor = foregroundColor
    self.backgroundColor = backgroundColor
    self.cornerRadius = cornerRadius
  }

  public var body: some View {

    GeometryReader { proxy in
      ZStack {

        backgroundColor

        switch direction {
        case .horizontal:
          HStack {
            foregroundColor
              .frame(width: proxy.size.width * max(min(1, displayProgress), 0))
            Spacer(minLength: 0)
          }

        case .vertical:
          VStack {
            Spacer(minLength: 0)
            foregroundColor
              .frame(height: proxy.size.height * max(min(1, displayProgress), 0))
          }

        }

      }
      .clipShape(
        RoundedRectangle(
          cornerRadius: cornerRadius,
          style: .continuous
        )
        .inset(by: { if isTracking { 0 } else { 4 } }())
      )
      .animation(.bouncy, value: isTracking)
      .animation(
        .bouncy,
        value: { () -> Double in
          if isTracking {
            return 0
          } else {
            return progress
          }
        }()
      )
      .gesture(
        DragGesture(minimumDistance: 0)
          .updating(
            $trackingState,
            body: { value, trackingState, transaction in

              if trackingState == nil {
                trackingState = .init(
                  beginProgress: progress
                )

                #if os(iOS)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                #endif
              }
            }
          )
          .onChanged({ value in

            guard let trackingState else {
              return
            }

            let constantSpeedProgress = {
              switch direction {
              case .horizontal:
                value.translation.width / proxy.size.width
              case .vertical:
                -value.translation.height / proxy.size.height
              }
            }()

            let progressChanges = constantSpeedProgress * speed
            let newProgress = max(min(1, trackingState.beginProgress + progressChanges), 0)

            if continuous {
              progress = newProgress
            } else {
              draggingProgress = newProgress
            }

          })
          .onEnded { _ in
            if !continuous, let finalProgress = draggingProgress {
              progress = finalProgress
              draggingProgress = nil
            }
            #if os(iOS)
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            #endif
          }
      )
    }
    .frame(minWidth: 4, minHeight: 4)

  }

}

#Preview {
  @Previewable @State var continuousValue: Double = 0.5
  @Previewable @State var discreteValue: Double = 0.5

  VStack(spacing: 32) {
    VStack(spacing: 8) {
      Text("Continuous (updates while dragging)")
        .font(.caption)
        .foregroundStyle(.secondary)
      TouchSlider(
        direction: .horizontal,
        value: $continuousValue,
        speed: 0.5,
        continuous: true,
        foregroundColor: .red,
        backgroundColor: Color.gray.opacity(0.3),
        cornerRadius: 6
      )
      .frame(height: 28)
      Text("Value: \(continuousValue, specifier: "%.2f")")
    }

    VStack(spacing: 8) {
      Text("Non-continuous (updates on release)")
        .font(.caption)
        .foregroundStyle(.secondary)
      TouchSlider(
        direction: .horizontal,
        value: $discreteValue,
        speed: 0.5,
        continuous: false,
        foregroundColor: .blue,
        backgroundColor: Color.gray.opacity(0.3),
        cornerRadius: 6
      )
      .frame(height: 28)
      Text("Value: \(discreteValue, specifier: "%.2f")")
    }
  }
  .padding()
}
