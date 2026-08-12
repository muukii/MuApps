//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import Foundation
import MuComponents
import SwiftUI

/// The selectable effect modes displayed in the editor's persistent tab bar.
enum EditorEffectTab: Equatable {

  /// The LUT library and No LUT result.
  case lut

  /// Relative color-temperature and tint correction.
  case whiteBalance

  /// Photographic exposure-value correction.
  case exposure

  /// Temporal Optical Flow motion blur.
  case motionBlur

  /// Post-grade film grain.
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
        accessibilityIdentifier: "editor-effect-tab-adjust",
        isSelected: isAdjustSelected
      ) { stackedView in

        if isAdjustSelected == false {
          selection = .whiteBalance
        }

        stackedView.wrappedValue.append(
          AnyView(
            AdjustMenu(selection: $selection)
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

  /// Keeps the nested adjustment selection live while NavigationToolbar owns
  /// the type-erased level in its navigation stack.
  private struct AdjustMenu: View {

    @Binding var selection: EditorEffectTab

    var body: some View {
      Container {
        EditorEffectTabBar.EditorEffectTabButton(
          title: "White Balance",
          systemImage: "thermometer.medium",
          accessibilityIdentifier: "editor-effect-tab-white-balance",
          isSelected: selection == .whiteBalance
        ) { _ in
          selection = .whiteBalance
        }

        EditorEffectTabBar.EditorEffectTabButton(
          title: "Exposure",
          systemImage: "sun.max",
          accessibilityIdentifier: "editor-effect-tab-exposure",
          isSelected: selection == .exposure
        ) { _ in
          selection = .exposure
        }
      }
    }
  }

  private var isAdjustSelected: Bool {
    switch selection {
    case .whiteBalance, .exposure:
      return true
    case .lut, .motionBlur, .grain:
      return false
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
