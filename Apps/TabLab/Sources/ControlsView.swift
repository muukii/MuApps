import SwiftUI

/// Control panel for the experiment. Lives inside its own tab so changes apply
/// to the surrounding `TabView` live.
struct ControlsView: View {
  @Binding var config: LabConfiguration
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass

  var body: some View {
    NavigationStack {
      Form {
        placementSection
        liveSection
        liquidGlassSection
        structureSection
        tipsSection
      }
      .navigationTitle("TabLab")
    }
  }

  // MARK: - Sections

  private var placementSection: some View {
    Section {
      Picker("Placement", selection: $config.placement) {
        ForEach(TabPlacement.allCases) { placement in
          VStack(alignment: .leading, spacing: 2) {
            Text(placement.title)
            Text(placement.summary)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .tag(placement)
        }
      }
      .pickerStyle(.inline)
      .labelsHidden()
    } header: {
      Text("Tab placement · tabViewStyle")
    } footer: {
      Text("On iPhone every style keeps the bar at the bottom. The difference shows on iPad (regular width).")
    }
  }

  private var liveSection: some View {
    Section("What you should see right now") {
      LabeledContent("Width class", value: widthClassText)
      Label {
        Text(liveExplanation)
      } icon: {
        Image(systemName: "eye")
          .foregroundStyle(.tint)
      }
      .font(.callout)
    }
  }

  private var liquidGlassSection: some View {
    Section {
      Picker("Minimize behavior", selection: $config.minimizeBehavior) {
        ForEach(TabBarMinimize.allCases) { behavior in
          Text(behavior.title).tag(behavior)
        }
      }
      Toggle("Bottom accessory", isOn: $config.showsBottomAccessory)
    } header: {
      Text("Liquid Glass (iOS 26)")
    } footer: {
      Text("Minimize collapses the bar as you scroll. The bottom accessory rides above the bar and shifts between expanded and inline placement.")
    }
  }

  private var structureSection: some View {
    Section {
      Toggle("Group tabs into TabSections", isOn: $config.usesSections)
      Toggle("Add a search tab (role: .search)", isOn: $config.showsSearchTab)
    } header: {
      Text("Structure")
    } footer: {
      Text("TabSections become labelled groups in the iPad sidebar. The search role pins a tab to the trailing edge / bottom-right.")
    }
  }

  private var tipsSection: some View {
    Section("Try this") {
      Label("Run on an iPad and pick \"Sidebar Adaptable\", then tap the sidebar button.", systemImage: "sidebar.left")
      Label("Scroll a content tab with minimize set to \"On scroll down\".", systemImage: "arrow.down")
      Label("Rotate / resize an iPad window to cross the compact ⇄ regular boundary.", systemImage: "rectangle.split.2x1")
    }
    .font(.callout)
  }

  // MARK: - Derived text

  private var widthClassText: String {
    switch horizontalSizeClass {
    case .compact: "Compact"
    case .regular: "Regular"
    case .none: "Unknown"
    @unknown default: "Unknown"
    }
  }

  private var liveExplanation: String {
    let isRegular = horizontalSizeClass == .regular
    switch config.placement {
    case .automatic:
      return isRegular
        ? "Floating tab bar across the top, no sidebar toggle."
        : "Tab bar pinned to the bottom."
    case .sidebarAdaptable:
      return isRegular
        ? "Top tab bar with a sidebar button — tap it to morph into a side bar."
        : "Bottom tab bar; the sidebar collapses away at compact width."
    case .page:
      return "Paging ignores width class — swipe horizontally between tabs."
    }
  }
}

#Preview {
  @Previewable @State var config = LabConfiguration()
  ControlsView(config: $config)
}
