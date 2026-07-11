import SwiftUI

private struct _Book: View {

  var body: some View {
    Menu("Up") {
      VStack {
        Text("Hello")
        Image(systemName: "star")
        HStack {
          Text("Hello")
          Image(systemName: "star")
        }
      }
    }
  }
}

#Preview("Menu") {
  _Book()
}
