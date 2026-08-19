import Foundation
import JournalIntents
import JournalVault
import SwiftUI

/// Native review surface presented by the iOS share extension.
///
/// This layer owns the model and does nothing else. Every value the review UI
/// renders is extracted here so `JournalShareViewContent` stays constructible
/// from literals, which is what makes the sheet previewable without an App
/// Group, a host app, or a posting service.
public struct JournalShareView: View {
  @Bindable var model: JournalShareModel

  public init(model: JournalShareModel) {
    self.model = model
  }

  public var body: some View {
    JournalShareViewContent(
      isLoading: model.isLoading,
      isPosting: model.isPosting,
      canPost: model.canPost,
      vaultOptions: model.writableVaults.map { $0.vaultOption },
      sharedItems: model.payloads.map { $0.sharedItem },
      warnings: model.warnings,
      errorMessage: model.errorMessage,
      selectedVaultID: $model.selectedVaultID,
      comment: $model.comment,
      commentKind: $model.commentKind,
      onCancel: { model.cancel() },
      onPost: { model.post() }
    )
  }
}

// MARK: - Content

/// Stateless review sheet. Every input is a plain value, a binding, or a
/// callback, so it renders identically in a preview and in the extension.
private struct JournalShareViewContent: View {

  /// One selectable destination, with its title already normalized.
  struct VaultOption: Identifiable, Hashable {
    let id: VaultID
    let title: String
  }

  /// One review row describing an imported payload.
  struct SharedItem: Identifiable, Hashable {
    let id: UUID
    let title: String
    let symbolName: String
  }

  let isLoading: Bool
  let isPosting: Bool
  let canPost: Bool
  let vaultOptions: [VaultOption]
  let sharedItems: [SharedItem]
  let warnings: [JournalShareLoadWarning]
  let errorMessage: String?

  @Binding var selectedVaultID: VaultID?
  @Binding var comment: String
  @Binding var commentKind: JournalShareCommentKind

  let onCancel: @MainActor @Sendable () -> Void
  let onPost: @MainActor @Sendable () -> Void

  var body: some View {
    NavigationStack {
      Form {
        if isLoading {
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
          Button("Cancel", action: onCancel)
            .disabled(isPosting)
        }

        ToolbarItem(placement: .confirmationAction) {
          Button("Post", action: onPost)
            .fontWeight(.semibold)
            .disabled(canPost == false)
        }
      }
      .interactiveDismissDisabled(isPosting)
    }
  }

  private var destinationSection: some View {
    Section("Vault") {
      if vaultOptions.isEmpty {
        Label(
          "No writable vault is available. Open Tinycurve to create a vault or check its sharing permission.",
          systemImage: "exclamationmark.triangle"
        )
        .foregroundStyle(.secondary)
      } else {
        Picker("Post to", selection: $selectedVaultID) {
          Text("Select a Vault")
            .tag(VaultID?.none)
          ForEach(vaultOptions) { option in
            Text(option.title)
              .tag(Optional(option.id))
          }
        }
      }
    }
  }

  private var commentSection: some View {
    Section {
      Picker("Comment Kind", selection: $commentKind) {
        Text("Text").tag(JournalShareCommentKind.text)
        Text("Todo").tag(JournalShareCommentKind.todo)
      }
      .pickerStyle(.segmented)
      .labelsHidden()

      commentField
    } header: {
      Text("Comment")
    } footer: {
      switch commentKind {
      case .text:
        Text("A comment is added under the shared content in the new entry.")
      case .todo:
        Text("An incomplete Todo is added under the shared content in the new entry.")
      }
    }
  }

  /// Comment editor whose affordance matches the kind being authored, mirroring
  /// the app composer's incomplete-Todo marker.
  @ViewBuilder
  private var commentField: some View {
    switch commentKind {
    case .text:
      TextField("Add an optional comment", text: $comment, axis: .vertical)
        .lineLimit(2...5)

    case .todo:
      HStack(alignment: .center, spacing: 8) {
        Image(systemName: "circle")
          .font(.body.weight(.semibold))
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)

        TextField("Add an optional todo", text: $comment, axis: .vertical)
          .lineLimit(1...5)
      }
    }
  }

  private var sharedItemsSection: some View {
    Section("Shared Items") {
      ForEach(sharedItems) { item in
        Label {
          Text(item.title)
            .lineLimit(2)
        } icon: {
          Image(systemName: item.symbolName)
            .foregroundStyle(.tint)
        }
      }
    }
  }

  @ViewBuilder
  private var warningSection: some View {
    if warnings.isEmpty == false {
      Section {
        ForEach(warnings) { warning in
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
    if let errorMessage {
      Section {
        Label(errorMessage, systemImage: "exclamationmark.circle")
          .foregroundStyle(.red)
      }
    }

    if isPosting {
      Section {
        HStack(spacing: 12) {
          ProgressView()
          Text("Posting…")
            .foregroundStyle(.secondary)
        }
      }
    }
  }
}

// MARK: - Display Mapping

extension JournalWritableVault {
  /// Picker row whose blank catalog title is replaced by a stable placeholder.
  fileprivate var vaultOption: JournalShareViewContent.VaultOption {
    let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    return .init(
      id: id,
      title: trimmedTitle.isEmpty ? String(localized: "Untitled Vault") : trimmedTitle
    )
  }
}

extension JournalSharePayload {
  fileprivate var sharedItem: JournalShareViewContent.SharedItem {
    .init(id: id, title: title, symbolName: symbolName)
  }
}

// MARK: - Previews

extension JournalShareViewContent.VaultOption {
  fileprivate static let personal = Self(id: VaultID(), title: "Personal")
  fileprivate static let team = Self(id: VaultID(), title: "Team Notes")
}

extension JournalShareViewContent.SharedItem {
  fileprivate static let link = Self(id: UUID(), title: "example.com", symbolName: "link")
  fileprivate static let text = Self(
    id: UUID(),
    title: "Example Domain — a page reserved for use in documentation",
    symbolName: "text.alignleft"
  )
  fileprivate static let photo = Self(id: UUID(), title: "Photo", symbolName: "photo")
  fileprivate static let file = Self(id: UUID(), title: "Quarterly.pdf", symbolName: "doc")
}

#Preview("Shared Link") {
  @Previewable @State var vaultID: VaultID? = JournalShareViewContent.VaultOption.personal.id
  @Previewable @State var comment = "Worth revisiting before Friday."
  @Previewable @State var commentKind: JournalShareCommentKind = .text

  JournalShareViewContent(
    isLoading: false,
    isPosting: false,
    canPost: true,
    vaultOptions: [.personal, .team],
    sharedItems: [.link],
    warnings: [],
    errorMessage: nil,
    selectedVaultID: $vaultID,
    comment: $comment,
    commentKind: $commentKind,
    onCancel: {},
    onPost: {}
  )
}

#Preview("Todo Comment") {
  @Previewable @State var vaultID: VaultID? = JournalShareViewContent.VaultOption.personal.id
  @Previewable @State var comment = "Read this later"
  @Previewable @State var commentKind: JournalShareCommentKind = .todo

  JournalShareViewContent(
    isLoading: false,
    isPosting: false,
    canPost: true,
    vaultOptions: [.personal, .team],
    sharedItems: [.link],
    warnings: [],
    errorMessage: nil,
    selectedVaultID: $vaultID,
    comment: $comment,
    commentKind: $commentKind,
    onCancel: {},
    onPost: {}
  )
}

#Preview("Loading") {
  @Previewable @State var vaultID: VaultID?
  @Previewable @State var comment = ""
  @Previewable @State var commentKind: JournalShareCommentKind = .text

  JournalShareViewContent(
    isLoading: true,
    isPosting: false,
    canPost: false,
    vaultOptions: [],
    sharedItems: [],
    warnings: [],
    errorMessage: nil,
    selectedVaultID: $vaultID,
    comment: $comment,
    commentKind: $commentKind,
    onCancel: {},
    onPost: {}
  )
}

/// Every degraded state at once: a host that vended several attachments, one
/// that could not be imported, no writable destination, and a failed post.
#Preview("Degraded States") {
  @Previewable @State var vaultID: VaultID?
  @Previewable @State var comment = ""
  @Previewable @State var commentKind: JournalShareCommentKind = .text

  JournalShareViewContent(
    isLoading: false,
    isPosting: false,
    canPost: false,
    vaultOptions: [],
    sharedItems: [.text, .link, .photo, .file],
    warnings: [
      .init(message: "Folders can't be posted yet. Share an individual file instead."),
      .init(message: "“Archive.zip” couldn't be loaded."),
    ],
    errorMessage: "The selected Journal Vault is no longer available.",
    selectedVaultID: $vaultID,
    comment: $comment,
    commentKind: $commentKind,
    onCancel: {},
    onPost: {}
  )
}

#Preview("Posting") {
  @Previewable @State var vaultID: VaultID? = JournalShareViewContent.VaultOption.team.id
  @Previewable @State var comment = "Read this later"
  @Previewable @State var commentKind: JournalShareCommentKind = .todo

  JournalShareViewContent(
    isLoading: false,
    isPosting: true,
    canPost: false,
    vaultOptions: [.personal, .team],
    sharedItems: [.link],
    warnings: [],
    errorMessage: nil,
    selectedVaultID: $vaultID,
    comment: $comment,
    commentKind: $commentKind,
    onCancel: {},
    onPost: {}
  )
}
