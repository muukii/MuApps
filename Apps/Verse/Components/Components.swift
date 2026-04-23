import SwiftUI

public struct ToggleButtonStyle: ButtonStyle {
  
  @Environment(\.colorScheme) private var colorScheme

  public var isOn: Bool

  public func makeBody(configuration: Configuration) -> some View {

    configuration.label
      .hidden()
      .padding(6)
      .background(
        Capsule()
          .fill(.thinMaterial)
          .environment(\.colorScheme, {
            switch colorScheme {
            case .light: return .dark
            case .dark: return .light
            default: return colorScheme
            }
          }())
          .mask {
            if isOn {
              ZStack {
                Color.white
                configuration.label
                  .foregroundStyle(.black)
              }
              .compositingGroup()
              .luminanceToAlpha()
            } else {
              configuration.label
            }
          }
      )
  }

  public init(isOn: Bool) {
    self.isOn = isOn
  }
}

#Preview {
  VStack(spacing: 16) {
    Button("Toggle On") {}
      .buttonStyle(ToggleButtonStyle(isOn: true))

    Button("Toggle Off") {}
      .buttonStyle(ToggleButtonStyle(isOn: false))
  }
  .padding()
  .tint(.red)
  .background(.purple)
}

#Preview {
  @Previewable @State var isOn: Bool = false
  Button(action: {
    isOn.toggle()
  }) {
    Image(systemName: "power.circle")      
  }
  .buttonStyle(ToggleButtonStyle(isOn: isOn))
}
