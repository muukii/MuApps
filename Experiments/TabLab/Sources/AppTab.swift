import SwiftUI

/// A single tab's identity and display data.
///
/// Modelled as a struct with static constants rather than an enum: every tab
/// shares the same shape (id / title / icon / tint) and nothing branches on the
/// tab itself, so it is a data bag, not a set of behaviours. Identity for
/// `TabView` selection is derived from `id` alone.
struct AppTab: Identifiable, Hashable {
  let id: String
  let title: String
  let systemImage: String
  let tint: Color

  static func == (lhs: AppTab, rhs: AppTab) -> Bool {
    lhs.id == rhs.id
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(id)
  }
}

extension AppTab {
  static let controls = AppTab(
    id: "controls",
    title: "Controls",
    systemImage: "slider.horizontal.3",
    tint: .gray
  )

  static let home = AppTab(
    id: "home",
    title: "Home",
    systemImage: "house.fill",
    tint: .blue
  )

  static let browse = AppTab(
    id: "browse",
    title: "Browse",
    systemImage: "square.grid.2x2.fill",
    tint: .orange
  )

  static let activity = AppTab(
    id: "activity",
    title: "Activity",
    systemImage: "chart.bar.fill",
    tint: .green
  )

  static let settings = AppTab(
    id: "settings",
    title: "Settings",
    systemImage: "gearshape.fill",
    tint: .purple
  )

  static let search = AppTab(
    id: "search",
    title: "Search",
    systemImage: "magnifyingglass",
    tint: .pink
  )
}
