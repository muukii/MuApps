import SwiftUI

/// Live configuration driving the TabView experiment. Every field is bound to a
/// control in `ControlsView`; mutating it re-renders the whole `TabView` so the
/// effect is visible immediately.
struct LabConfiguration {
  var placement: TabPlacement = .sidebarAdaptable
  var minimizeBehavior: TabBarMinimize = .automatic
  var usesSections: Bool = true
  var showsSearchTab: Bool = false
  var showsBottomAccessory: Bool = true
}

// MARK: - Options

/// The `tabViewStyle` to apply — the core of the bottom / top / side experiment.
///
/// An enum, not a struct: `RootView` switches on it exhaustively to map onto the
/// concrete `TabViewStyle` values, and adding a case should force that mapping to
/// be updated.
enum TabPlacement: String, CaseIterable, Identifiable {
  case automatic
  case sidebarAdaptable
  case page

  var id: String { rawValue }

  var title: String {
    switch self {
    case .automatic: "Automatic"
    case .sidebarAdaptable: "Sidebar Adaptable"
    case .page: "Page"
    }
  }

  /// One-line description of how this style lays out across size classes.
  var summary: String {
    switch self {
    case .automatic:
      "iPhone: bottom bar · iPad: floating top bar"
    case .sidebarAdaptable:
      "iPhone: bottom bar · iPad: top bar ⇄ side bar"
    case .page:
      "Full-screen horizontal paging (swipe between tabs)"
    }
  }
}

/// Maps onto `TabBarMinimizeBehavior` (iOS 26). Controls whether the Liquid Glass
/// tab bar collapses as content scrolls.
enum TabBarMinimize: String, CaseIterable, Identifiable {
  case automatic
  case never
  case onScrollDown

  var id: String { rawValue }

  var title: String {
    switch self {
    case .automatic: "Automatic"
    case .never: "Never"
    case .onScrollDown: "On scroll down"
    }
  }
}
