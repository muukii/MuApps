//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import SwiftUI

/// Manages the user's LUT collection: import from Files, browse, delete.
struct LUTLibraryView: View {

  let library: LUTLibrary
  @Environment(\.dismiss) private var dismiss

  @State private var isImporting = false
  @State private var errorMessage: String?

  var body: some View {
    NavigationStack {
      List {
        Section {
          ForEach(library.luts) { lut in
            row(for: lut)
          }
        } footer: {
          Text("Import .cube LUTs or square image LUTs (.png / .jpg) from Files.")
        }
      }
      .navigationTitle("LUTs")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("Done") { dismiss() }
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button {
            isImporting = true
          } label: {
            Image(systemName: "plus")
          }
          .accessibilityLabel("Import LUT")
        }
      }
      .fileImporter(
        isPresented: $isImporting,
        allowedContentTypes: LUTLibrary.importableContentTypes,
        allowsMultipleSelection: true
      ) { result in
        handleImport(result)
      }
      .alert(
        "Import failed",
        isPresented: Binding(
          get: { errorMessage != nil },
          set: { if $0 == false { errorMessage = nil } }
        ),
        presenting: errorMessage
      ) { _ in
        Button("OK", role: .cancel) {}
      } message: { message in
        Text(message)
      }
    }
  }

  private func row(for lut: LUT) -> some View {
    HStack {
      Image(systemName: lut.format == .cube ? "cube" : "photo")
        .foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 2) {
        Text(lut.name)
        Text("\(lut.format == .cube ? "Cube" : "Image") • \(lut.dimension)³")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      if lut.isBundled {
        Text("Starter")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
    .swipeActions {
      if lut.isBundled == false {
        Button(role: .destructive) {
          library.delete(lut)
        } label: {
          Label("Delete", systemImage: "trash")
        }
      }
    }
  }

  private func handleImport(_ result: Result<[URL], any Error>) {
    switch result {
    case .success(let urls):
      for url in urls {
        do {
          try library.importLUT(from: url)
        } catch {
          errorMessage = error.localizedDescription
        }
      }
    case .failure(let error):
      errorMessage = error.localizedDescription
    }
  }
}
