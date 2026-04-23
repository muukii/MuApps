//
//  FeatureFlagsSettingsView.swift
//  YouTubeSubtitle
//
//  Created by Claude on 2025/12/09.
//

import SwiftUI

/// Settings section for configuring feature flags.
/// Only available in DEBUG builds.
struct FeatureFlagsSettingsView: View {
  private let featureFlags = FeatureFlags.shared

  var body: some View {
    Section {
      ForEach(FeatureFlag.allCases) { flag in
        FeatureFlagRow(flag: flag, featureFlags: featureFlags)
      }

      Button(role: .destructive) {
        featureFlags.resetToDefaults()
      } label: {
        Label("Reset All to Defaults", systemImage: "arrow.counterclockwise")
      }
    } header: {
      Label("Feature Flags", systemImage: "flag.fill")
    } footer: {
      Text("Toggle experimental features. Changes take effect immediately.")
    }
  }
}

// MARK: - Feature Flag Row

private struct FeatureFlagRow: View {
  let flag: FeatureFlag
  let featureFlags: FeatureFlags

  var body: some View {
    if featureFlags.canToggle(flag) {
      // swift-state-graph の $property.binding を使用
      Toggle(isOn: featureFlags.binding(for: flag)) {
        VStack(alignment: .leading, spacing: 2) {
          Text(flag.displayName)
          Text(flag.description)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    } else {
      // コンパイル時に強制されている場合は表示のみ
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text(flag.displayName)
          Text(flag.description)
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Spacer()

        Text(featureFlags.isEnabled(flag) ? "Forced ON" : "Forced OFF")
          .font(.caption)
          .foregroundStyle(.tertiary)
      }
    }
  }
}

// MARK: - Preview

#if DEBUG
#Preview {
  NavigationStack {
    List {
      FeatureFlagsSettingsView()
    }
  }
}
#endif
