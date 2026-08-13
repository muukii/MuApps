import SwiftUI

/// Root of the experiment. Owns the live `LabConfiguration` and rebuilds the
/// `TabView` whenever it changes so the bottom / top / side behaviour is visible
/// the instant a control is toggled.
struct RootView: View {
  @State private var config = LabConfiguration()
  @State private var selection: AppTab = .home

  var body: some View {
    TabView(selection: $selection) {
      Tab(AppTab.controls.title, systemImage: AppTab.controls.systemImage, value: AppTab.controls) {
        ControlsView(config: $config)
      }

      if config.usesSections {
        TabSection("Main") { mainTabs }
        TabSection("Library") { libraryTabs }
      } else {
        mainTabs
        libraryTabs
      }

      if config.showsSearchTab {
        Tab(
          AppTab.search.title,
          systemImage: AppTab.search.systemImage,
          value: AppTab.search,
          role: .search
        ) {
          DemoTabContent(tab: .search)
        }
      }
    }
    .applyTabPlacement(config.placement)
    .applyMinimizeBehavior(config.minimizeBehavior)
    .bottomAccessory(isEnabled: config.showsBottomAccessory, config: config)
    .animation(.smooth, value: config.showsSearchTab)
    .animation(.smooth, value: config.showsBottomAccessory)
  }

  // MARK: - Tab Groups

  @TabContentBuilder<AppTab>
  private var mainTabs: some TabContent<AppTab> {
    Tab(AppTab.home.title, systemImage: AppTab.home.systemImage, value: AppTab.home) {
      DemoTabContent(tab: .home)
    }
    Tab(AppTab.browse.title, systemImage: AppTab.browse.systemImage, value: AppTab.browse) {
      DemoTabContent(tab: .browse)
    }
  }

  @TabContentBuilder<AppTab>
  private var libraryTabs: some TabContent<AppTab> {
    Tab(AppTab.activity.title, systemImage: AppTab.activity.systemImage, value: AppTab.activity) {
      DemoTabContent(tab: .activity)
    }
    Tab(AppTab.settings.title, systemImage: AppTab.settings.systemImage, value: AppTab.settings) {
      DemoTabContent(tab: .settings)
    }
  }
}

// MARK: - Config-driven modifiers

extension View {
  /// Applies the chosen `tabViewStyle`. Each branch yields a different concrete
  /// style type, so `@ViewBuilder` is required to unify them.
  @ViewBuilder
  fileprivate func applyTabPlacement(_ placement: TabPlacement) -> some View {
    switch placement {
    case .automatic:
      tabViewStyle(.automatic)
    case .sidebarAdaptable:
      tabViewStyle(.sidebarAdaptable)
    case .page:
      tabViewStyle(.page)
    }
  }

  fileprivate func applyMinimizeBehavior(_ behavior: TabBarMinimize) -> some View {
    let resolved: TabBarMinimizeBehavior =
      switch behavior {
      case .automatic: .automatic
      case .never: .never
      case .onScrollDown: .onScrollDown
      }
    return tabBarMinimizeBehavior(resolved)
  }

  /// Conditionally attaches the bottom accessory so the toggle can add and remove
  /// it at runtime.
  @ViewBuilder
  fileprivate func bottomAccessory(isEnabled: Bool, config: LabConfiguration) -> some View {
    if isEnabled {
      tabViewBottomAccessory {
        BottomAccessoryView(config: config)
      }
    } else {
      self
    }
  }
}

#Preview {
  RootView()
}
