import CaptureAudio
import CaptureDoodle
import CapturePhoto
import CaptureText
import MuColor
import SwiftData
import SwiftUI

/// Dev gallery: launches each capture component in isolation on device. This is
/// scaffolding for developing the components independently while the real
/// journaling UI is undecided — not the shipping entry point.
struct CaptureGalleryView: View {
  var body: some View {
    NavigationStack {
      List {
        Section("Capture") {
          NavigationLink {
            TextCaptureDemoView()
          } label: {
            Label("Text", systemImage: "text.alignleft")
          }

          NavigationLink {
            PhotoCaptureDemoView()
          } label: {
            Label("Photo", systemImage: "camera")
          }

          NavigationLink {
            DoodleCaptureDemoView()
          } label: {
            Label("Doodle", systemImage: "scribble.variable")
          }

          NavigationLink {
            AudioCaptureDemoView()
          } label: {
            Label("Ambient Sound", systemImage: "waveform")
          }
        }

        Section("Storage") {
          NavigationLink {
            ContentView()
          } label: {
            Label("Entries (SwiftData / iCloud)", systemImage: "icloud")
          }
        }
      }
      .navigationTitle("Journal · Dev")
    }
  }
}

#Preview {
  CaptureGalleryView()
    .modelContainer(for: JournalEntry.self, inMemory: true)
}
