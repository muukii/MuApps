import SwiftUI

struct PatternAurora: View {

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
      scene: .aurora,
      isActive: isActive,
      isAdjustmentVisible: $isAdjustmentVisible,
      matrixX: MatrixBinding($parameters.speed, range: 0.1...2.0),
      matrixY: MatrixBinding($parameters.waveHeight, range: 0.1...1.0)
    ) {
      _BodyView(parameters: parameters, isActive: isActive)
    } settingsContent: {

      Text("Speed: \(parameters.speed, specifier: "%.2f")")
      Slider(value: $parameters.speed, in: 0.1...2.0)

      VStack(alignment: .leading) {
        Text("Wave Height: \(parameters.waveHeight, specifier: "%.2f")")
        Slider(value: $parameters.waveHeight, in: 0.1...1.0)
      }

      VStack(alignment: .leading) {
        Text("Flow Direction: \(parameters.flowDirection < 0.5 ? "Up" : "Down")")
        Slider(value: $parameters.flowDirection, in: 0.0...1.0)
      }

      ColorPicker("Color 1 (Top)", selection: $parameters.color1)
      ColorPicker("Color 2 (Middle)", selection: $parameters.color2)
      ColorPicker("Color 3 (Bottom)", selection: $parameters.color3)

      VStack(alignment: .leading) {
        Text("Peak Brightness: \(parameters.peakBrightness, specifier: "%.1f")x")
        Slider(value: $parameters.peakBrightness, in: 1.0...8.0)
      }
    }

  }

}

private struct ShaderParameters: Codable {
  var speed: Float = 0.5
  var waveHeight: Float = 0.5
  var flowDirection: Float = 0.0  // 0 = up, 1 = down

  // ベースカラー（ColorPicker用、0〜1の標準範囲）
  var _color1: CodableColor = .init(red: 0.0, green: 1.0, blue: 0.5)  // エメラルドグリーン
  var _color2: CodableColor = .init(red: 0.2, green: 0.5, blue: 1.0)  // ブルー
  var _color3: CodableColor = .init(red: 0.8, green: 0.2, blue: 1.0)  // パープル

  var color1: Color {
    get { _color1.color }
    set { _color1 = CodableColor(newValue) }
  }
  var color2: Color {
    get { _color2.color }
    set { _color2 = CodableColor(newValue) }
  }
  var color3: Color {
    get { _color3.color }
    set { _color3 = CodableColor(newValue) }
  }

  // ピーク輝度（1.0〜8.0）
  var peakBrightness: Float = 5

  // HDR カラー（シェーダーに渡す用）
  func hdrColor(_ color: Color, headroom: Float) -> Color {
    let resolved = color.resolve(in: EnvironmentValues())
    return Color(Color.ResolvedHDR(resolved, headroom: headroom))
  }

  enum CodingKeys: String, CodingKey {
    case speed, waveHeight, flowDirection
    case _color1 = "color1"
    case _color2 = "color2"
    case _color3 = "color3"
    case peakBrightness
  }
}

/// Metal Shaderを使ったオーロラエフェクト
private struct _BodyView: View {
  let parameters: ShaderParameters
  var isActive = true
  @Environment(\.deviceHeadroom) private var deviceHeadroom

  var body: some View {
    PhaseTimelineView(speed: parameters.speed, isActive: isActive) { phase, size in
      Rectangle()
        .fill(.black)
        .colorEffect(
          ShaderLibrary.aurora(
            .float2(size),
            .float(phase),
            .float(1.0),  // speed is already integrated into phase
            .float(parameters.waveHeight),
            .float(parameters.flowDirection),
            .float(parameters.peakBrightness),
            .float(deviceHeadroom),
            .color(parameters.hdrColor(parameters.color1, headroom: deviceHeadroom)),
            .color(parameters.hdrColor(parameters.color2, headroom: deviceHeadroom)),
            .color(parameters.hdrColor(parameters.color3, headroom: deviceHeadroom))
          )
        )
    }
    .blur(radius: 30)
  }
}

// MARK: - Preview

#Preview("Aurora") {
  _BodyView(parameters: ShaderParameters())
}
