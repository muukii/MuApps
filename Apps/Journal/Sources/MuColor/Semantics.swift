import SwiftUI
import UIKit

public struct Palette: Sendable {

  public static let `default` = Palette(assetNamespace: "Theme/WarmCream", colorScheme: .light)

  // MARK: - Seeds (素の色は 6 つ)

  /// Accent color for controls, focused affordances, and content that should
  /// inherit SwiftUI's `Color.accentColor`/`.tint` role.
  public var tint: Color

  /// Foreground color for text and icons displayed directly on a `tint` surface.
  public var onTint: Color

  public var primaryContainer: Color
  public var onPrimaryContainer: Color
  public var secondaryContainer: Color
  public var onSecondaryContainer: Color

  public init(
    tint: Color,
    onTint: Color,
    primaryContainer: Color,
    onPrimaryContainer: Color,
    secondaryContainer: Color,
    onSecondaryContainer: Color
  ) {
    self.tint = tint
    self.onTint = onTint
    self.primaryContainer = primaryContainer
    self.onPrimaryContainer = onPrimaryContainer
    self.secondaryContainer = secondaryContainer
    self.onSecondaryContainer = onSecondaryContainer
  }

  /// Loads the six seed colors from MuColor's asset catalog.
  ///
  /// `assetNamespace` is the namespaced asset catalog path shared by one theme,
  /// such as `Theme/WarmCream`. Each color set stores its light value as Any and
  /// its dark override as the Dark appearance.
  init(assetNamespace: String, colorScheme: ColorScheme) {
    self.init(
      tint: Self.color(named: "\(assetNamespace)/Tint", colorScheme: colorScheme),
      onTint: Self.color(named: "\(assetNamespace)/OnTint", colorScheme: colorScheme),
      primaryContainer: Self.color(named: "\(assetNamespace)/PrimaryContainer", colorScheme: colorScheme),
      onPrimaryContainer: Self.color(
        named: "\(assetNamespace)/OnPrimaryContainer",
        colorScheme: colorScheme
      ),
      secondaryContainer: Self.color(named: "\(assetNamespace)/SecondaryContainer", colorScheme: colorScheme),
      onSecondaryContainer: Self.color(
        named: "\(assetNamespace)/OnSecondaryContainer",
        colorScheme: colorScheme
      )
    )
  }

  private static func color(named name: String, colorScheme: ColorScheme) -> Color {
    guard let color = UIColor(
      named: name,
      in: .module,
      compatibleWith: UITraitCollection(colorScheme: colorScheme)
    ) else {
      fatalError("Missing MuColor asset named \(name).")
    }
    return Color(uiColor: color)
  }

  // MARK: - Derived (seed 色の不透明度違いのみ。新しい色相は足さない)

  /// primary 面上の副次文字。
  public var onPrimaryContainerVariant: Color {
    onPrimaryContainer.opacity(0.55)
  }
  /// secondary 面上の副次文字・メタラベル。
  public var onSecondaryContainerVariant: Color {
    onSecondaryContainer.opacity(0.55)
  }
  /// 標準の境界。
  public var outline: Color { onSecondaryContainer.opacity(0.14) }
  /// 最も淡いヘアライン。
  public var outlineVariant: Color { onSecondaryContainer.opacity(0.08) }
  /// 触覚ドットのハロー・tint の極薄塗り。
  public var tintRing: Color { tint.opacity(0.18) }

}

private extension UITraitCollection {

  convenience init(colorScheme: ColorScheme) {
    switch colorScheme {
    case .light:
      self.init(userInterfaceStyle: .light)
    case .dark:
      self.init(userInterfaceStyle: .dark)
    @unknown default:
      self.init(userInterfaceStyle: .light)
    }
  }
}

extension EnvironmentValues {
  /// The active palette. Injected by `PrimaryContainer`; read it to derive raw
  /// `Color`/`UIColor` values where a `ShapeStyle` won't do (e.g. configuring a
  /// `UINavigationBarAppearance`).
  @Entry public var appPalette: Palette = .default
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

  // MARK: - Seeds

  public struct PrimaryContainer: ShapeStyle {
    public func resolve(in environment: EnvironmentValues) -> some ShapeStyle {
      _PaletteReader(keyPath: \.primaryContainer)
    }
  }

  public struct OnTint: ShapeStyle {
    public func resolve(in environment: EnvironmentValues) -> some ShapeStyle {
      _PaletteReader(keyPath: \.onTint)
    }
  }

  public struct OnPrimaryContainer: ShapeStyle {
    public func resolve(in environment: EnvironmentValues) -> some ShapeStyle {
      _PaletteReader(keyPath: \.onPrimaryContainer)
    }
  }

  public struct SecondaryContainer: ShapeStyle {
    public func resolve(in environment: EnvironmentValues) -> some ShapeStyle {
      _PaletteReader(keyPath: \.secondaryContainer)
    }
  }

  public struct OnSecondaryContainer: ShapeStyle {
    public func resolve(in environment: EnvironmentValues) -> some ShapeStyle {
      _PaletteReader(keyPath: \.onSecondaryContainer)
    }
  }

  // MARK: - Derived

  public struct OnPrimaryContainerVariant: ShapeStyle {
    public func resolve(in environment: EnvironmentValues) -> some ShapeStyle {
      _PaletteReader(keyPath: \.onPrimaryContainerVariant)
    }
  }

  public struct OnSecondaryContainerVariant: ShapeStyle {
    public func resolve(in environment: EnvironmentValues) -> some ShapeStyle {
      _PaletteReader(keyPath: \.onSecondaryContainerVariant)
    }
  }

  public struct Outline: ShapeStyle {
    public func resolve(in environment: EnvironmentValues) -> some ShapeStyle {
      _PaletteReader(keyPath: \.outline)
    }
  }

  public struct OutlineVariant: ShapeStyle {
    public func resolve(in environment: EnvironmentValues) -> some ShapeStyle {
      _PaletteReader(keyPath: \.outlineVariant)
    }
  }

  public struct TintRing: ShapeStyle {
    public func resolve(in environment: EnvironmentValues) -> some ShapeStyle {
      _PaletteReader(keyPath: \.tintRing)
    }
  }

}

extension ShapeStyle where Self == AppShapeStyles.PrimaryContainer {
  public static var appPrimaryContainer: Self { AppShapeStyles.PrimaryContainer() }
}

extension ShapeStyle where Self == AppShapeStyles.OnTint {
  public static var appOnTint: Self { AppShapeStyles.OnTint() }
}

extension ShapeStyle where Self == AppShapeStyles.OnPrimaryContainer {
  public static var appOnPrimaryContainer: Self { AppShapeStyles.OnPrimaryContainer() }
}

extension ShapeStyle where Self == AppShapeStyles.SecondaryContainer {
  public static var appSecondaryContainer: Self { AppShapeStyles.SecondaryContainer() }
}

extension ShapeStyle where Self == AppShapeStyles.OnSecondaryContainer {
  public static var appOnSecondaryContainer: Self { AppShapeStyles.OnSecondaryContainer() }
}

public struct PrimaryContainer<Content: View>: View {

  @Environment(\.appPalette) private var inheritedPalette
  @Environment(\.colorScheme) private var colorScheme

  private let theme: Theme?
  private let overridePalette: Palette?
  private let content: Content

  /// Root use: resolves the light/dark surface from the current `colorScheme`.
  public init(theme: Theme, @ViewBuilder content: () -> Content) {
    self.theme = theme
    self.overridePalette = nil
    self.content = content()
  }

  /// Explicit palette, or inherit the active palette when `nil` (nested use).
  public init(palette: Palette? = nil, @ViewBuilder content: () -> Content) {
    self.theme = nil
    self.overridePalette = palette
    self.content = content()
  }

  public var body: some View {
    let palette = resolvedPalette
    content
      .backgroundStyle(AppShapeStyles.PrimaryContainer())
      .foregroundStyle(AppShapeStyles.OnPrimaryContainer())
      .tint(palette.tint)
      .environment(\.appPalette, palette)
  }

  private var resolvedPalette: Palette {
    if let theme {
      return theme.palette(for: colorScheme)
    }
    return overridePalette ?? inheritedPalette
  }
}

public struct SecondaryContainer: View {

  private let content: AnyView

  public init<Content: View>(@ViewBuilder content: () -> Content) {
    self.content = AnyView(content())
  }

  public var body: some View {
    content
      .backgroundStyle(AppShapeStyles.SecondaryContainer())
      .foregroundStyle(AppShapeStyles.OnSecondaryContainer())
  }

}

#Preview {
  ScrollView {

    ForEach(Theme.all) { theme in
      PrimaryContainer(theme: theme) {
        VStack {
          Text(theme.name)
            .padding()

          SecondaryContainer {
            Text("Secondary Container")
              .padding()
              .background(.background)
          }
          .clipShape(
            ConcentricRectangle(
              corners: .concentric,
              isUniform: true
            )
          )
          .padding()
        }
        .background(
          ConcentricRectangle(
            corners: .concentric,
            isUniform: true
          )
          .fill(.background)
        )
      }
      .containerShape(
        .rect(cornerRadius: 24)
      )
      .padding()
    }

  }
}
