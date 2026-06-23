import HexColorMacro
import SwiftUI
import UIKit

public struct Palette: Sendable {
 
  public static let `default` = Palette(
    tint: #hexColor("#C56B43", colorSpace: .displayP3),
    primaryContainer: #hexColor("#F2E9D8", colorSpace: .displayP3),
    onPrimaryContainer: #hexColor("#2A241D", colorSpace: .displayP3)
  )    
  
  public var tint: Color    
  public var primaryContainer: Color
  public var onPrimaryContainer: Color
  
  public init(
    tint: Color,
    primaryContainer: Color,
    onPrimaryContainer: Color,
  ) {
    self.tint = tint
    self.primaryContainer = primaryContainer
    self.onPrimaryContainer = onPrimaryContainer
  }
    
}

extension EnvironmentValues {
  @Entry var appPalette: Palette = .default
}

public enum AppShapeStyles {
  
  private struct _PaletteReader: ShapeStyle {
    
    private let keyPath: any KeyPath<Palette, Color> & Sendable
    
    init(keyPath: any KeyPath<Palette, Color> & Sendable) {
      self.keyPath = keyPath
    }
    
    func resolve(in environment: EnvironmentValues) -> some ShapeStyle {
      environment.appPalette[keyPath: keyPath]
    }
    
  }
  
  public struct PrimaryContainer: ShapeStyle {
    
    public func resolve(in environment: EnvironmentValues) -> some ShapeStyle {
      _PaletteReader(keyPath: \.primaryContainer)
    }
    
  }
  
  public struct OnPrimaryContainer: ShapeStyle {
    
    public func resolve(in environment: EnvironmentValues) -> some ShapeStyle {
      _PaletteReader(keyPath: \.onPrimaryContainer)
    }
    
  }
  
}

public struct PaletteContainer<Content: View>: View {
  
  private let palette: Palette
  private let content: Content
  
  public init(palette: Palette, @ViewBuilder content: () -> Content) {
    self.palette = palette
    self.content = content()
  }
  
  public var body: some View {
    content
      .backgroundStyle(AppShapeStyles.PrimaryContainer())
      .foregroundStyle(AppShapeStyles.OnPrimaryContainer())
      .tint(palette.tint)
      .environment(\.appPalette, palette)
  }
}

#Preview {
  VStack {
    Text("Primary Container")
      .padding()
      .background(AppShapeStyles.PrimaryContainer())
      .foregroundStyle(AppShapeStyles.OnPrimaryContainer())
  }
  .environment(
    \.appPalette,
     Palette(
      tint: .green,
      primaryContainer: .blue,
      onPrimaryContainer: .white
     )
  )
}
