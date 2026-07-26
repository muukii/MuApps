//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//
// Färg — a parametric (FeatureTree) LUT-on-video editor and exporter.
// Built on BrightroomParametric. Designed to grow into a standalone product.
//

import AVFoundation
import SwiftUI

/// UserDefaults keys that control Färg's app-level presentation.
private enum FargDefaults {

  /// Whether the first-launch introduction has finished on this device.
  static let hasCompletedOnboarding = "farg.onboarding.completed"
}

/// Configures process-wide policies before presenting Färg's first scene.
@main
struct FargApp: App {

  init() {
    // AVFoundation requires this opt-in before the first player or player item
    // is initialized; changing the policy after that point raises an exception.
    AVPlayer.isObservationEnabled = true

    VideoPlaybackAudioSessionPolicy.configureForMixedPlayback()
  }

  var body: some Scene {
    WindowGroup {
      FargAppRootView()
    }
  }
}

/// Routes a first launch through onboarding before constructing the editor home.
private struct FargAppRootView: View {

  @AppStorage(FargDefaults.hasCompletedOnboarding)
  private var hasCompletedOnboarding = false
  /// The shared LUT library is constructed at launch so its bundled starter
  /// import completes before either onboarding or the editor becomes visible.
  @State private var library = LUTLibrary()

  var body: some View {
    Group {
      if hasCompletedOnboarding {
        RootView(library: library)
          .transition(.opacity)
      } else {
        FargOnboardingView(
          onComplete: {
            hasCompletedOnboarding = true
          }
        )
        .transition(.opacity)
      }
    }
    .animation(.smooth, value: hasCompletedOnboarding)
  }
}
