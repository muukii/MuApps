import CaptureAudio
import CapturePhoto
import CaptureSuggestions
import CaptureText
import JournalModel
import MuColor
import MuHaptics
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
          .listRowBackground(Rectangle().fill(.appSecondaryContainer))

          NavigationLink {
            PhotoCaptureDemoView()
          } label: {
            Label("Photo", systemImage: "camera")
          }

          NavigationLink {
            DoodleCaptureView()
          } label: {
            Label("Doodle", systemImage: "scribble.variable")
          }

          NavigationLink {
            AudioCaptureDemoView()
          } label: {
            Label("Ambient Sound", systemImage: "waveform")
          }

          NavigationLink {
            SuggestionCaptureDemoView()
          } label: {
            Label("Suggestions", systemImage: "sparkles")
          }
        }

        Section("Lab") {
          NavigationLink {
            HapticEditorView()
          } label: {
            Label("Haptics", systemImage: "iphone.radiowaves.left.and.right")
          }
        }

        Section("Storage") {
          NavigationLink {
            ListView()
          } label: {
            Label("Entries (SwiftData / iCloud)", systemImage: "icloud")
          }
        }
      }
      .scrollContentBackground(.hidden)
      .background(.background)
      .navigationTitle("Journal · Dev")
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          NavigationLink {
            SettingsView()
          } label: {
            Label("Settings", systemImage: "gearshape")
          }
        }
      }
    }
    .appNavigationBarStyle()
  }
}

#Preview {
  CaptureGalleryView()
    .modelContainer(for: Card.self, inMemory: true)
}
