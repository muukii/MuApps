import CaptureAudio
import CaptureBauhaus
import CapturePhoto
import CaptureSuggestions
import CaptureText
import JournalModel
import MuColor
#if DEBUG
import MuHaptics
#endif
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
            BauhausGridCaptureDemoView()
          } label: {
            Label("Bauhaus Grid", systemImage: "square.grid.3x3.square")
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

        #if DEBUG
          Section("Lab") {
            NavigationLink {
              HapticEditorView()
            } label: {
              Label("Haptics", systemImage: "iphone.radiowaves.left.and.right")
            }

            NavigationLink {
              HapticTapSequencerView()
            } label: {
              Label("Haptic Doodle", systemImage: "hand.tap")
            }
          }
        #endif

        Section("Storage") {
          NavigationLink {
            SavedListView()
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
    .modelContainer(try! ModelContainer(
      for: JournalStore.schema,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    ))
}
