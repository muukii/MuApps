//
//  AppContainer.swift
//  AmbientLight
//
//  Created by Hiroshi Kimura on 2026/02/12.
//

import SwiftUI

@Observable
final class AppContainer {

  private var isAppActive = false
  private var isLightEmissionActive = true

  /// Updates whether Calm Light is currently the foreground interactive scene.
  func setScenePhase(_ scenePhase: ScenePhase) {
    isAppActive = scenePhase == .active
    synchronizeIdleTimer()
  }

  /// Updates whether the display should stay awake for an emitting light session.
  ///
  /// Timer expiration sets this to `false`, allowing the system to sleep again
  /// even while the app remains in the foreground on a black resting screen.
  func setLightEmissionActive(_ isActive: Bool) {
    isLightEmissionActive = isActive
    synchronizeIdleTimer()
  }

  private func synchronizeIdleTimer() {
    UIApplication.shared.isIdleTimerDisabled = isAppActive && isLightEmissionActive
  }

}
