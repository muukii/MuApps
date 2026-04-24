import Photos
import SwiftUI

struct ContentView: View {

  @State private var manager = PhotoLibraryManager()

  var body: some View {
    NavigationStack {
      Group {
        switch manager.authorizationStatus {
        case .notDetermined:
          VStack(spacing: 16) {
            Image(systemName: "photo.on.rectangle.angled")
              .font(.system(size: 60))
              .foregroundStyle(.secondary)
            Text("Access your photo library to find large files")
              .multilineTextAlignment(.center)
            Button("Grant Access") {
              Task {
                await manager.requestAuthorization()
              }
            }
            .buttonStyle(.borderedProminent)
          }
          .padding()

        case .authorized, .limited:
          PhotoGridView(manager: manager)

        case .denied:
          VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
              .font(.system(size: 60))
              .foregroundStyle(.secondary)
            Text("Photo library access is denied. Please enable it in Settings.")
              .multilineTextAlignment(.center)
          }
          .padding()
        }
      }
      .navigationTitle("PhotosOrganizer")
      .navigationDestination(for: PHAsset.self) { asset in
        PhotoDetailView(asset: asset, manager: manager)
      }
    }
    .task {
      await manager.checkCurrentAuthorization()
    }
  }
}

#Preview {
  ContentView()
}
