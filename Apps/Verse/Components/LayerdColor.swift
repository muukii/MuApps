import SwiftUI

extension Color {
  
  public init(hex: Int) {
    let red = Double((hex >> 16) & 0xFF) / 255.0
    let green = Double((hex >> 8) & 0xFF) / 255.0
    let blue = Double(hex & 0xFF) / 255.0
    self.init(red: red, green: green, blue: blue)
  }
  
}

private struct ExampleView: View {

  var body: some View {
    VStack {

      Text("Color Panel")
        .font(.title.bold())

      Rectangle()
        .foregroundStyle(.secondary)
      Rectangle()
        .foregroundStyle(.tertiary)
      Rectangle()
        .foregroundStyle(.quaternary)
      Rectangle()
        .foregroundStyle(.quinary)
    }    
  }
}

public struct TintContainer<Content: View>: View {

  @Environment(\.colorScheme) var colorScheme

  let content: Content
  let darkColor: Color
  let brightColor: Color

  public init(
    brightColor: Color,
    darkColor: Color,
    @ViewBuilder content: () -> Content
  ) {
    self.content = content()
    self.darkColor = darkColor
    self.brightColor = brightColor
  }

  public var body: some View {
    ZStack {
      Rectangle()
        .ignoresSafeArea()
        .foregroundStyle(.primary)

      content
        .foregroundStyle(.tint)
        .tint(
          {
            switch colorScheme {
            case .dark:
              return darkColor
            default:
              return brightColor
            }
          }()
        )

    }
    .foregroundStyle(.tint)
    .tint(
      {
        switch colorScheme {
        case .dark:
          return brightColor
        default:
          return darkColor
        }
      }()
    )

  }
}

#Preview("LayerdColor") {
  TintContainer(
    brightColor: .black,
    darkColor: .init(hex: 0xA8BBAE)
  ) {
    ExampleView()
  }
}

#Preview("NightMode") { 
  TintContainer(
    brightColor: .black,
    darkColor: .init(hex: 0xFB0301)
  ) {
    ExampleView()
  }
}
