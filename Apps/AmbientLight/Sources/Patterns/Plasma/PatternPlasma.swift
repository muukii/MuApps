import SwiftUI

struct PatternPlasma: View {

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
      scene: .plasma,
      isActive: isActive,
      isAdjustmentVisible: $isAdjustmentVisible,
      matrixX: MatrixBinding($parameters.speed, range: 0.1...3.0),
      matrixY: MatrixBinding($parameters.frequency, range: 0.5...5.0)
    ) {
      _BodyView(parameters: parameters, isActive: isActive)
    } settingsContent: {

      Text("Speed: \(parameters.speed, specifier: "%.2f")")
      Slider(value: $parameters.speed, in: 0.1...3.0)

      VStack(alignment: .leading) {
        Text("Frequency: \(parameters.frequency, specifier: "%.1f")")
        Slider(value: $parameters.frequency, in: 0.5...5.0)
      }

      VStack(alignment: .leading) {
        Text("Complexity: \(parameters.complexity, specifier: "%.1f")")
        Slider(value: $parameters.complexity, in: 1.0...5.0)
      }

      VStack(alignment: .leading) {
        Text("Color Speed: \(parameters.colorSpeed, specifier: "%.2f")")
        Slider(value: $parameters.colorSpeed, in: 0.1...2.0)
      }

      VStack(alignment: .leading) {
        Text("Saturation: \(parameters.saturation, specifier: "%.2f")")
        Slider(value: $parameters.saturation, in: 0.0...1.0)
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
  var speed: Float = 1.0
  var frequency: Float = 2.0
  var complexity: Float = 2.0
  var colorSpeed: Float = 0.5
  var saturation: Float = 0.8

  // ベースカラー（ColorPicker用、色相オフセットとして使用）
  var _baseColor: CodableColor = .init(red: 1.0, green: 0.5, blue: 0.8)

  var baseColor: Color {
    get { _baseColor.color }
    set { _baseColor = CodableColor(newValue) }
  }

  // ピーク輝度（1.0〜8.0）
  var peakBrightness: Float = 4.0

  // HDR カラー（シェーダーに渡す用）
  func hdrColor(headroom: Float) -> Color {
    let resolved = baseColor.resolve(in: EnvironmentValues())
    return Color(Color.ResolvedHDR(resolved, headroom: headroom))
  }

  enum CodingKeys: String, CodingKey {
    case speed, frequency, complexity, colorSpeed, saturation
    case _baseColor = "baseColor"
    case peakBrightness
  }
}

/// Metal Shaderを使ったプラズマエフェクト
private struct _BodyView: View {
  let parameters: ShaderParameters
  var isActive = true
  @Environment(\.deviceHeadroom) private var deviceHeadroom

  var body: some View {
    PhaseTimelineView(speed: parameters.speed, isActive: isActive) { phase, size in
      Rectangle()
        .fill(.black)
        .colorEffect(
          ShaderLibrary.plasma(
            .float2(size),
            .float(phase),
            .float(1.0),  // speed is already integrated into phase
            .float(parameters.frequency),
            .float(parameters.complexity),
            .float(parameters.colorSpeed),
            .float(parameters.saturation),
            .float(parameters.peakBrightness),
            .float(deviceHeadroom),
            .color(parameters.hdrColor(headroom: deviceHeadroom))
          )
        )
    }
    .blur(radius: 30)
  }
}

// MARK: - Preview

#Preview("Plasma") {
  _BodyView(parameters: ShaderParameters())
}
