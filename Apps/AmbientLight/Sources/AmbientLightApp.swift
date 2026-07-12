//
//  AmbientLightApp.swift
//  AmbientLight
//
//  Created by Hiroshi Kimura on 2026/02/09.
//

import SwiftUI

@main
struct AmbientLightApp: App {

  let container = AppContainer()
  @Environment(\.scenePhase) private var scenePhase

  var body: some Scene {
    WindowGroup {
      RootView()
        .tint(Color(red: 0.98, green: 0.69, blue: 0.36))
        .statusBarHidden()
    }
    .environment(container)
    .onChange(of: scenePhase) { _, newPhase in
      container.setScenePhase(newPhase)
    }
  }

}

private struct RootView: View {

  var body: some View {
    DeviceHeadroomReader {
      ContentView()
        .background(.black)
    }
  }
}
