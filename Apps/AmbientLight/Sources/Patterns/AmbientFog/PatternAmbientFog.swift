import SwiftUI

struct PatternAmbientFog: View {

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
      scene: .ambientFog,
      isActive: isActive,
      isAdjustmentVisible: $isAdjustmentVisible,
      matrixX: MatrixBinding($parameters.speed, range: 0.1...2.0),
      matrixY: MatrixBinding($parameters.dimFactor, range: 0.0...1.0)
    ) {
      _BodyView(parameters: parameters, isActive: isActive)
    } settingsContent: {

      Text("Speed: \(parameters.speed, specifier: "%.2f")")
      Slider(value: $parameters.speed, in: 0.1...2.0)

      VStack(alignment: .leading) {
        Text("Dim Factor: \(parameters.dimFactor, specifier: "%.2f")")
        Slider(value: $parameters.dimFactor, in: 0.0...1.0)
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
  var dimFactor: Float = 0  // 最も暗い時の輝度（0.0〜1.0）

  // グリッドサイズ
  var gridCols: Float = 1
  var gridRows: Float = 6

  // ベースカラー（ColorPicker用、0〜1の標準範囲）
  var _baseColor: CodableColor = .init(hex: 0xed6a18)

  var baseColor: Color {
    get { _baseColor.color }
    set { _baseColor = CodableColor(newValue) }
  }

  // ピーク輝度（ノイズが最大の時の明るさ倍率、1.0〜8.0）
  // 1.0 = HDRカラーそのまま、8.0 = HDRカラーの8倍の明るさ
  var peakBrightness: Float = 3

  // HDR カラー（シェーダーに渡す用）
  func hdrColor(headroom: Float) -> Color {
    let resolved = baseColor.resolve(in: EnvironmentValues())
    return Color(Color.ResolvedHDR(resolved, headroom: headroom))
  }

  enum CodingKeys: String, CodingKey {
    case speed, dimFactor, gridCols, gridRows
    case _baseColor = "baseColor"
    case peakBrightness
  }
}

/// Metal Shaderを使った1/f揺らぎアンビエントライト
/// GPUで直接ノイズ計算を行うため、CPUの負荷が低い
private struct _BodyView: View {
  let parameters: ShaderParameters
  var isActive = true
  @Environment(\.deviceHeadroom) private var deviceHeadroom

  var body: some View {
    PhaseTimelineView(speed: parameters.speed, isActive: isActive) { phase, size in
      Rectangle()
        .fill(.black)
        .colorEffect(
          ShaderLibrary.ambientFog(
            .float2(size),
            .float(phase),
            .float(parameters.gridCols),
            .float(parameters.gridRows),
            .float(1.0),  // speed is already integrated into phase
            .float(parameters.dimFactor),
            .float(parameters.peakBrightness),
            .float(deviceHeadroom),
            .color(parameters.hdrColor(headroom: deviceHeadroom))
          )
        )
    }
    .blur(radius: 100)
  }
}

// MARK: - Preview

#Preview("Metal Ambient Light") {
  _BodyView(parameters: ShaderParameters())
}
