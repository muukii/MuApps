//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//
// BrightroomVideo — a parametric (FeatureTree) LUT-on-video editor and exporter.
// Built on BrightroomParametric. Designed to grow into a standalone product.
//

import SwiftUI

@main
struct BrightroomVideoApp: App {

  init() {
    // Register the iOS 26 continued-processing task handler before any submit.
    BackgroundExportCoordinator.shared.registerHandler()
  }

  var body: some Scene {
    WindowGroup {
      RootView()
    }
  }
}
