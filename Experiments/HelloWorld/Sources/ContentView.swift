import MuDesignSystem
import SwiftUI

struct ContentView: View {
  var body: some View {
    VStack(spacing: 16) {
      Image(systemName: "hand.wave.fill")
        .font(.system(size: 64))
        .foregroundStyle(MuColors.primary)
      Text("Hello, World!")
        .font(MuFonts.largeTitle())
    }
    .padding()
    .background(MuColors.background)
  }
}

#Preview {
  ContentView()
}
