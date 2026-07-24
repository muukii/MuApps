//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import SwiftUI

/// App root: owns the LUT library and the current edit, hosts the editor.
struct RootView: View {

  @State private var library = LUTLibrary()
  @State private var editState = EditState()

  var body: some View {
    NavigationStack {
      EditorView(library: library, editState: editState)
        .navigationTitle("BrightroomVideo")
        .navigationBarTitleDisplayMode(.inline)
    }
  }
}

#Preview {
  RootView()
}
