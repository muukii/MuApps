@_spi(Advanced) import SwiftUIIntrospect
import SwiftUI
import UIKit
import MuColor

/// Recolors the navigation bar's **title** and **icons** (bar-button items and the
/// back chevron) for the enclosing `NavigationStack`.
///
/// On iOS 26 SwiftUI exposes `.tint(_:)` for bar-button color but has no public
/// modifier to recolor `.navigationTitle` text, so this reaches the underlying
/// `UINavigationBar` via SwiftUIIntrospect and mutates a per-instance
/// `UINavigationBarAppearance`. The styling is assigned only to this stack's own
/// bar — it never touches the global `UINavigationBar.appearance()` proxy, so bars
/// owned by other view controllers (including SDKs) are unaffected.
///
/// The system background (Liquid Glass) is preserved unless `backgroundColor` is
/// given, in which case the bar becomes an opaque fill of that color.
///
/// ```swift
/// NavigationStack {
///   List { ... }
///     .navigationTitle("Journal")
///     .appNavigationBarStyle(titleColor: palette.onPrimaryContainer, iconColor: palette.tint)
/// }
/// ```
public struct AppNavigationBarStyle: Equatable, Sendable {

  /// Color of the navigation title, both inline and large.
  public var titleColor: Color

  /// Color of bar-button items and the back chevron.
  public var iconColor: Color

  /// Solid background fill. `nil` keeps the system background (Liquid Glass).
  public var backgroundColor: Color?

  public init(
    titleColor: Color,
    iconColor: Color,
    backgroundColor: Color? = nil
  ) {
    self.titleColor = titleColor
    self.iconColor = iconColor
    self.backgroundColor = backgroundColor
  }
}

extension View {

  /// Applies title/icon coloring to the underlying `UINavigationBar` of the
  /// enclosing `NavigationStack`. Apply inside the stack (e.g. on the root
  /// content), not outside it, so introspection can locate the bar.
  ///
  /// The version predicate is the `@_spi(Advanced)` range form `.iOS(.v26...)`,
  /// which matches iOS 26 *and every later OS* (the plain `.iOS(.v26)` form only
  /// fires when 26 is the current major, so it would no-op on iOS 27+).
  public func appNavigationBarStyle(_ style: AppNavigationBarStyle) -> some View {
    introspect(.navigationStack, on: .iOS(.v26...)) { navigationController in
      style.apply(to: navigationController.navigationBar)
    }
  }

  /// Convenience for the common title + icon case.
  public func appNavigationBarStyle(
    titleColor: Color,
    iconColor: Color,
    backgroundColor: Color? = nil
  ) -> some View {
    appNavigationBarStyle(
      AppNavigationBarStyle(
        titleColor: titleColor,
        iconColor: iconColor,
        backgroundColor: backgroundColor
      )
    )
  }
  
  public func appNavigationBarStyle() -> some View {
    modifier(AppNavigationBarStyleModifier())      
  }
}

struct AppNavigationBarStyleModifier: ViewModifier {
  
  @Environment(\.appPalette) private var palette

  func body(content: Content) -> some View {
    content
      .appNavigationBarStyle(
        titleColor: palette.onPrimaryContainer,
        iconColor: palette.tint
      )
  }
}

// MARK: - Appearance application

extension AppNavigationBarStyle {

  /// Mutates `bar`'s per-instance appearances in place. Title color is applied to
  /// copies of the bar's current appearances so the system background material is
  /// preserved; only `backgroundColor` opts into an opaque fill.
  fileprivate func apply(to bar: UINavigationBar) {

    let titleUIColor = UIColor(titleColor)
    let backgroundUIColor = backgroundColor.map(UIColor.init)

    bar.tintColor = UIColor(iconColor)
    bar.barTintColor = UIColor(iconColor)

    func restyled(_ source: UINavigationBarAppearance) -> UINavigationBarAppearance {
      let appearance = source.copy() as! UINavigationBarAppearance
      if let backgroundUIColor {
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = backgroundUIColor
        appearance.shadowColor = .clear
      }
      // Set title attributes last: configureWithOpaqueBackground resets them.
      appearance.titleTextAttributes[.foregroundColor] = titleUIColor
      appearance.largeTitleTextAttributes[.foregroundColor] = titleUIColor
      return appearance
    }
    bar.standardAppearance = restyled(bar.standardAppearance)
    // Leave scroll-edge / compact appearances nil when the system hasn't set
    // them — a nil appearance falls back to `standardAppearance`, which is
    // already styled above.
    bar.scrollEdgeAppearance = bar.scrollEdgeAppearance.map(restyled)
    bar.compactAppearance = bar.compactAppearance.map(restyled)
  }
}
