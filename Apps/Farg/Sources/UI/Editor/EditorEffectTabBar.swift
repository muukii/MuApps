//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import Foundation
import MuComponents
import SwiftUI

/// The selectable effect modes displayed in the editor's persistent tab bar.
enum EditorEffectTab: Equatable {
  case lut
  case exposure
  case motionBlur
  case grain
}

/// Keeps effect selection reachable while the active controls scroll above it.
struct EditorEffectTabBar: View {

  @Binding var selection: EditorEffectTab

  var body: some View {

    NavigationToolbar {
      topMenuItems
    }
    .padding(.horizontal, 24)

  }

  private struct Container<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
      self.content = content()
    }

    var body: some View {
      ScrollView(.horizontal) {
        HStack(spacing: 24) {
          content
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
      }
      .fixedSize(horizontal: true, vertical: false)

    }
  }

  @ViewBuilder
  var topMenuItems: some View {

    Container {
      EditorEffectTabBar.EditorEffectTabButton(
        title: "Look",
        systemImage: "circlebadge.2",
        accessibilityIdentifier: "editor-effect-tab-lut",
        isSelected: selection == .lut
      ) { _ in
        selection = .lut
      }

      EditorEffectTabBar.EditorEffectTabButton(
        title: "Adjust",
        systemImage: "slider.horizontal.3",
        accessibilityIdentifier: "editor-effect-tab-exposure",
        isSelected: selection == .exposure
      ) { stackedView in

        stackedView.wrappedValue.append(
          AnyView(
            Container {
              EditorEffectTabBar.EditorEffectTabButton(
                title: "Exposure",
                systemImage: "sun.max",
                accessibilityIdentifier: "editor-effect-tab-exposure",
                isSelected: true
              ) { _ in
                selection = .exposure
              }
            }
          )
        )
      }

      EditorEffectTabBar.EditorEffectTabButton(
        title: "Motion",
        systemImage: "app.background.dotted",
        accessibilityIdentifier: "editor-effect-tab-motion-blur",
        isSelected: selection == .motionBlur
      ) { _ in
        selection = .motionBlur
      }

      EditorEffectTabBar.EditorEffectTabButton(
        title: "Grain",
        systemImage: "water.waves",
        accessibilityIdentifier: "editor-effect-tab-grain",
        isSelected: selection == .grain
      ) { _ in
        selection = .grain
      }
    }
  }
  /// Represents one accessible effect mode in the editor's persistent tab bar.
  struct EditorEffectTabButton: View {

    @Environment(\.stackedView) var stackedView

    let title: LocalizedStringResource
    let systemImage: String
    let accessibilityIdentifier: String
    let isSelected: Bool
    let action: @MainActor @Sendable (Binding<[AnyView]>) -> Void

    var body: some View {
      Button(action: {
        action(stackedView)
      }) {
        VStack(spacing: 6) {
          Image(systemName: systemImage)
            .font(.body)
            .frame(
              width: 24,
              height: 24,
              alignment: .center
            )

          Text(title)
            .font(.caption.weight(isSelected ? .semibold : .regular))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(title)
      .foregroundStyle(
        isSelected ? Color.primary : Color.secondary
      )
      .overlay(alignment: .bottom) {
        Circle()
          .fill(.primary)
          .frame(width: 4, height: 4)
          .padding(.bottom, 5)
          .opacity(isSelected ? 1 : 0)
      }
      .accessibilityAddTraits(isSelected ? .isSelected : [])
      .accessibilityIdentifier(accessibilityIdentifier)
    }
  }
}

#Preview {
  @Previewable @State var selection: EditorEffectTab = .motionBlur
  EditorEffectTabBar(selection: $selection)
    .padding()
}
