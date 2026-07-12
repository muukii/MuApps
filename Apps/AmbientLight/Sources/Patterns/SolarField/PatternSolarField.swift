import SwiftUI

/// A bounded HDR light painting inspired by the warm radial projection of an optical lamp.
struct PatternSolarField: View {

  private let isActive: Bool
  @Binding private var isAdjustmentVisible: Bool
  @State private var parameters = SolarFieldParameters()

  init(
    isActive: Bool = true,
    isAdjustmentVisible: Binding<Bool> = .constant(false)
  ) {
    self.isActive = isActive
    _isAdjustmentVisible = isAdjustmentVisible
  }

  var body: some View {
    Display(
      scene: .solarField,
      isActive: isActive,
      isAdjustmentVisible: $isAdjustmentVisible,
      matrixX: MatrixBinding($parameters.horizontalOffset, range: -0.25...0.25),
      matrixY: MatrixBinding($parameters.verticalOffset, range: -0.25...0.25),
      usesEdgeGradientMask: false
    ) {
      SolarFieldBody(
        parameters: parameters,
        isActive: isActive
      )
    } settingsContent: {
      VStack(alignment: .leading) {
        Text("Circle Size: \(parameters.radius, specifier: "%.2f")")
        Slider(value: $parameters.radius, in: 0.35...0.85)
      }

      VStack(alignment: .leading) {
        Text("Rim Width: \(parameters.rimWidth, specifier: "%.3f")")
        Slider(value: $parameters.rimWidth, in: 0.01...0.12)
      }

      VStack(alignment: .leading) {
        Text("Bloom: \(parameters.bloomWidth, specifier: "%.2f")")
        Slider(value: $parameters.bloomWidth, in: 0.02...0.20)
      }

      ColorPicker("Center", selection: $parameters.centerColor)
      ColorPicker("Middle", selection: $parameters.middleColor)
      ColorPicker("Edge", selection: $parameters.edgeColor)
      ColorPicker("Rim", selection: $parameters.rimColor)
    }
  }
}

/// User-adjustable values that define the position, geometry, and emitted colors of Solar Field.
///
/// The background and HDR peak are deliberately absent: Solar Field always
/// returns to true black and derives its peak from the display's live EDR headroom.
private struct SolarFieldParameters: Codable {

  /// Horizontal displacement from the reference composition's center, in view-width units.
  var horizontalOffset: Float = -0.035

  /// Upward displacement from the reference composition's center, in view-height units.
  var verticalOffset: Float = 0

  /// Circle radius expressed as a fraction of the view's shorter dimension.
  var radius: Float = 0.595

  /// Width of the bright optical rim relative to the circle radius.
  var rimWidth: Float = 0.035

  /// Distance over which the exterior glow returns fully to black.
  var bloomWidth: Float = 0.11

  private var storedCenterColor = CodableColor(hex: 0xE6331A)
  private var storedMiddleColor = CodableColor(hex: 0xF48B32)
  private var storedEdgeColor = CodableColor(hex: 0xF7BF30)
  private var storedRimColor = CodableColor(hex: 0xFFE035)

  var centerColor: Color {
    get { storedCenterColor.color }
    set { storedCenterColor = CodableColor(newValue) }
  }

  var middleColor: Color {
    get { storedMiddleColor.color }
    set { storedMiddleColor = CodableColor(newValue) }
  }

  var edgeColor: Color {
    get { storedEdgeColor.color }
    set { storedEdgeColor = CodableColor(newValue) }
  }

  var rimColor: Color {
    get { storedRimColor.color }
    set { storedRimColor = CodableColor(newValue) }
  }
}

/// The stateless rendering surface that supplies view geometry and HDR headroom to Metal.
private struct SolarFieldBody: View {

  let parameters: SolarFieldParameters
  let isActive: Bool

  @Environment(\.deviceHeadroom) private var deviceHeadroom

  var body: some View {
    PhaseTimelineView(
      speed: 1,
      isActive: isActive,
      minimumInterval: 1 / 15
    ) { phase, size in
      Rectangle()
        .fill(.black)
        .colorEffect(
          ShaderLibrary.solarField(
            .float2(size),
            .float(phase),
            .float(parameters.horizontalOffset),
            .float(parameters.verticalOffset),
            .float(parameters.radius),
            .float(parameters.rimWidth),
            .float(parameters.bloomWidth),
            .float(deviceHeadroom),
            .color(parameters.centerColor),
            .color(parameters.middleColor),
            .color(parameters.edgeColor),
            .color(parameters.rimColor)
          )
        )
    }
    .ignoresSafeArea()
  }
}

#Preview("Solar Field") {
  SolarFieldBody(
    parameters: SolarFieldParameters(),
    isActive: true
  )
}
