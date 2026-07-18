import Foundation
import JournalIntents
import JournalVault
import SwiftUI

/// Native review surface presented by the iOS share extension.
struct JournalShareView: View {
  @Bindable var model: JournalShareModel

  var body: some View {
    NavigationStack {
      Form {
        if model.isLoading {
          Section {
            HStack(spacing: 12) {
              ProgressView()
              Text("Preparing shared items…")
                .foregroundStyle(.secondary)
            }
          }
        } else {
          destinationSection
          commentSection
          sharedItemsSection
          warningSection
          errorSection
        }
      }
      .navigationTitle("Post to Tinycurve")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            model.cancel()
          }
          .disabled(model.isPosting)
        }

        ToolbarItem(placement: .confirmationAction) {
          Button("Post") {
            model.post()
          }
          .fontWeight(.semibold)
          .disabled(model.canPost == false)
        }
      }
      .interactiveDismissDisabled(model.isPosting)
    }
  }

  private var destinationSection: some View {
    Section("Vault") {
      if model.writableVaults.isEmpty {
        Label(
          "No writable vault is available. Open Tinycurve to create a vault or check its sharing permission.",
          systemImage: "exclamationmark.triangle"
        )
        .foregroundStyle(.secondary)
      } else {
        Picker("Post to", selection: $model.selectedVaultID) {
          Text("Select a Vault")
            .tag(VaultID?.none)
          ForEach(model.writableVaults) { vault in
            Text(displayTitle(for: vault))
              .tag(Optional(vault.id))
          }
        }
      }
    }
  }

  private var commentSection: some View {
    Section {
      TextField("Add an optional comment", text: $model.comment, axis: .vertical)
        .lineLimit(2...5)
    } header: {
      Text("Comment")
    } footer: {
      Text("A comment becomes the first piece of content in the new entry.")
    }
  }

  private var sharedItemsSection: some View {
    Section("Shared Items") {
      ForEach(model.payloads) { payload in
        Label {
          Text(payload.title)
            .lineLimit(2)
        } icon: {
          Image(systemName: payload.symbolName)
            .foregroundStyle(.tint)
        }
      }
    }
  }

  @ViewBuilder
  private var warningSection: some View {
    if model.warnings.isEmpty == false {
      Section {
        ForEach(model.warnings) { warning in
          Label(warning.message, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.orange)
        }
      } header: {
        Text("Not Included")
      } footer: {
        Text("Review the list above before posting the remaining items.")
      }
    }
  }

  @ViewBuilder
  private var errorSection: some View {
    if let errorMessage = model.errorMessage {
      Section {
        Label(errorMessage, systemImage: "exclamationmark.circle")
          .foregroundStyle(.red)
      }
    }

    if model.isPosting {
      Section {
        HStack(spacing: 12) {
          ProgressView()
          Text("Posting…")
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  private func displayTitle(for vault: JournalWritableVault) -> String {
    let title = vault.title.trimmingCharacters(in: .whitespacesAndNewlines)
    return title.isEmpty ? String(localized: "Untitled Vault") : title
  }
}
