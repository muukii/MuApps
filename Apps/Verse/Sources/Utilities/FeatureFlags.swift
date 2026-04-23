//
//  FeatureFlags.swift
//  YouTubeSubtitle
//
//  Created by Claude on 2025/12/08.
//

import Foundation
import StateGraph
import SwiftUI

// MARK: - Feature Flag Definition

/// Defines all available feature flags in the app.
/// Each flag has a key for storage, display name for UI, and default value.
enum FeatureFlag: String, CaseIterable, Identifiable {
  case downloadFeature = "featureFlag.downloadFeature"
  // Future flags can be added here:
  // case experimentalPlayer = "featureFlag.experimentalPlayer"

  var id: String { rawValue }

  /// Display name shown in Settings UI
  var displayName: String {
    switch self {
    case .downloadFeature:
      return "Download Feature"
    }
  }

  /// Description shown in Settings UI
  var description: String {
    switch self {
    case .downloadFeature:
      return "Show download button and status indicators."
    }
  }

  /// Default runtime value (used when no stored value exists)
  var defaultValue: Bool {
    switch self {
    case .downloadFeature:
      return true
    }
  }

  /// Compile-time override. Returns `nil` if no compile-time override exists.
  /// When returns `false`, the feature is forcibly disabled regardless of runtime value.
  var compileTimeOverride: Bool? {
    switch self {
    case .downloadFeature:
      #if DEBUG
      return nil  // No override in DEBUG - use runtime value
      #else
      return false  // Force disabled in Release builds
      #endif
    }
  }
}

// MARK: - Feature Flags Service

/// Feature flags for controlling app functionality.
/// Provides runtime-configurable flags with compile-time overrides for release builds.
///
/// Usage:
/// ```swift
/// if FeatureFlags.shared.isEnabled(.downloadFeature) { ... }
/// // or for backward compatibility:
/// if FeatureFlags.shared.isDownloadFeatureEnabled { ... }
/// ```
@MainActor
final class FeatureFlags {
  /// Shared singleton instance
  static let shared = FeatureFlags()

  private init() {}

  // MARK: - Stored Flags (UserDefaults backed)

  @GraphStored(backed: .userDefaults(key: "featureFlag.downloadFeature"))
  var downloadFeatureFlag: Bool = true

  // MARK: - Public API

  /// Check if a feature flag is enabled.
  /// Respects compile-time overrides, then falls back to runtime stored value.
  func isEnabled(_ flag: FeatureFlag) -> Bool {
    // Check compile-time override first
    if let compileTimeValue = flag.compileTimeOverride {
      return compileTimeValue
    }
    // Use runtime value
    return runtimeValue(for: flag)
  }

  private func runtimeValue(for flag: FeatureFlag) -> Bool {
    switch flag {
    case .downloadFeature:
      return downloadFeatureFlag
    }
  }

  /// Check if a flag can be toggled at runtime (no compile-time override)
  func canToggle(_ flag: FeatureFlag) -> Bool {
    flag.compileTimeOverride == nil
  }

  /// Get binding for a feature flag (for use in Toggle views)
  func binding(for flag: FeatureFlag) -> Binding<Bool> {
    switch flag {
    case .downloadFeature:
      return $downloadFeatureFlag.binding
    }
  }

  /// Reset all flags to their default values
  func resetToDefaults() {
    downloadFeatureFlag = FeatureFlag.downloadFeature.defaultValue
  }

  // MARK: - Backward Compatibility

  /// Controls whether video download functionality is visible in the UI.
  ///
  /// When disabled:
  /// - Download button is hidden in PlayerView
  /// - Download status indicators are hidden in HomeView
  /// - DownloadView sheet is not accessible
  ///
  /// Note: Backend download functionality (DownloadManager) remains available
  /// for programmatic use (e.g., for transcription purposes).
  var isDownloadFeatureEnabled: Bool {
    isEnabled(.downloadFeature)
  }
}
