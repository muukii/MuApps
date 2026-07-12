import SwiftUI

struct PatternFire: View {

  private let isActive: Bool
  @Binding private var isAdjustmentVisible: Bool
  @State private var parameters = ShaderParameters()

  init(
    isActive: Bool = true,
    isAdjustmentVisible: Binding<Bool> = .constant(false)
  ) {
    self.isActive = isActive
    _isAdjustmentVisible = isAdjustmentVisible
  }

  var body: some View {

    Display(
      scene: .firelight,
      isActive: isActive,
      isAdjustmentVisible: $isAdjustmentVisible,
      matrixX: MatrixBinding($parameters.speed, range: 0.1...2.0),
      matrixY: MatrixBinding($parameters.flameHeight, range: 0.1...1.0)
    ) {
      _BodyView(parameters: parameters, isActive: isActive)
    } settingsContent: {

      VStack(alignment: .leading) {
        Text("Speed: \(parameters.speed, specifier: "%.2f")")
        Slider(value: $parameters.speed, in: 0.1...2.0)
      }

      VStack(alignment: .leading) {
        Text("Flame Height: \(parameters.flameHeight, specifier: "%.2f")")
        Slider(value: $parameters.flameHeight, in: 0.1...1.0)
      }

      VStack(alignment: .leading) {
        Text("Flame Width: \(parameters.flameWidth, specifier: "%.2f")")
        Slider(value: $parameters.flameWidth, in: 0.5...3.0)
      }

      VStack(alignment: .leading) {
        Text("Turbulence: \(parameters.turbulence, specifier: "%.2f")")
        Slider(value: $parameters.turbulence, in: 0.0...2.0)
      }

      VStack(alignment: .leading) {
        Text("Sparks: \(parameters.sparkAmount, specifier: "%.2f")")
        Slider(value: $parameters.sparkAmount, in: 0.0...2.0)
      }

      ColorPicker("Base Color", selection: $parameters.baseColor)

      VStack(alignment: .leading) {
        Text("Peak Brightness: \(parameters.peakBrightness, specifier: "%.1f")x")
        Slider(value: $parameters.peakBrightness, in: 1.0...8.0)
      }
    }

  }

}

private struct ShaderParameters: Codable {
  var speed: Float = 0.5
  var flameHeight: Float = 0.2  // Low value for fireball effect
  var flameWidth: Float = 1.5
  var turbulence: Float = 1.0
  var sparkAmount: Float = 1.0
  var smokeAmount: Float = 0.0

  var _baseColor: CodableColor = .init(red: 1.0, green: 0.9, blue: 0.7)

  var baseColor: Color {
    get { _baseColor.color }
    set { _baseColor = CodableColor(newValue) }
  }

  var peakBrightness: Float = 3.0

  func hdrColor(headroom: Float) -> Color {
    let resolved = baseColor.resolve(in: EnvironmentValues())
    return Color(Color.ResolvedHDR(resolved, headroom: headroom))
  }

  enum CodingKeys: String, CodingKey {
    case speed, flameHeight, flameWidth, turbulence, sparkAmount, smokeAmount
    case _baseColor = "baseColor"
    case peakBrightness
  }
}

private struct _BodyView: View {
  let parameters: ShaderParameters
  var isActive = true
  @Environment(\.deviceHeadroom) private var deviceHeadroom

  var body: some View {
    PhaseTimelineView(speed: parameters.speed, isActive: isActive) { phase, size in
      Rectangle()
        .fill(.black)
        .colorEffect(
          ShaderLibrary.fire(
            .float2(size),
            .float(phase),
            .float(1.0),
            .float(parameters.flameHeight),
            .float(parameters.flameWidth),
            .float(parameters.turbulence),
            .float(parameters.sparkAmount),
            .float(parameters.smokeAmount),
            .float(parameters.peakBrightness),
            .float(deviceHeadroom),
            .color(parameters.hdrColor(headroom: deviceHeadroom))
          )
        )
    }
    .blur(radius: 10)
  }
}

// MARK: - Preview

#Preview("Fire") {
  _BodyView(parameters: ShaderParameters())
}
