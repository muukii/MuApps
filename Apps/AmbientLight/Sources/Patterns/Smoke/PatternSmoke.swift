import SwiftUI

struct PatternSmoke: View {

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
      scene: .smoke,
      isActive: isActive,
      isAdjustmentVisible: $isAdjustmentVisible,
      matrixX: MatrixBinding($parameters.speed, range: 0.1...2.0),
      matrixY: MatrixBinding($parameters.density, range: 0.5...2.0)
    ) {
      _BodyView(parameters: parameters, isActive: isActive)
    } settingsContent: {

      VStack(alignment: .leading) {
        Text("Speed: \(parameters.speed, specifier: "%.2f")")
        Slider(value: $parameters.speed, in: 0.1...2.0)
      }

      VStack(alignment: .leading) {
        Text("Density: \(parameters.density, specifier: "%.2f")")
        Slider(value: $parameters.density, in: 0.5...2.0)
      }

      VStack(alignment: .leading) {
        Text("Scale: \(parameters.scale, specifier: "%.1f")")
        Slider(value: $parameters.scale, in: 0.5...5.0)
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
  var density: Float = 1.0
  var scale: Float = 1.0

  var _baseColor: CodableColor = .init(red: 0.8, green: 0.9, blue: 1.0)

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
    case speed, density, scale
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
          ShaderLibrary.smoke(
            .float2(size),
            .float(phase),
            .float(1.0),
            .float(parameters.density),
            .float(parameters.scale),
            .float(parameters.peakBrightness),
            .float(deviceHeadroom),
            .color(parameters.hdrColor(headroom: deviceHeadroom))
          )
        )
    }
    .blur(radius: 4)
  }
}

// MARK: - Preview

#Preview("Smoke") {
  _BodyView(parameters: ShaderParameters())
}
