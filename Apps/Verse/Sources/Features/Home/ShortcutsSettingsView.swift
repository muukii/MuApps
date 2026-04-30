//
//  ShortcutsSettingsView.swift
//  YouTubeSubtitle
//
//  Created by Hiroshi Kimura on 2025/12/02.
//

import SwiftUI
import AppIntents

struct ShortcutsSettingsView: View {
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List {
        #if os(iOS)
          Section {
            SiriTipView(intent: OpenYouTubeVideoIntent())
          } header: {
            Text("Open Video")
          } footer: {
            Text("Use Siri to quickly open YouTube videos with subtitles.")
          }
        #endif

        Section {
#if os(iOS)
          ShortcutsLink()
            .shortcutsLinkStyle(.automaticOutline)
#else
          Link(destination: URL(string: "shortcuts://")!) {
            Label("Open Shortcuts", systemImage: "link")
          }
#endif
        } header: {
          Text("Shortcuts App")
        } footer: {
          Text("Create custom shortcuts with the Shortcuts app.")
        }
      }
      .navigationTitle("Siri & Shortcuts")
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") {
            dismiss()
          }
        }
      }
    }
  }
}

#Preview {
  ShortcutsSettingsView()
}
