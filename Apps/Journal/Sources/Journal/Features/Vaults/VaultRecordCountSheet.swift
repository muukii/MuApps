#if DEBUG

  import JournalVault
  import MuColor
  import SwiftUI

  /// Debug sheet comparing one vault's local rows with the records CloudKit holds.
  ///
  /// `CKSyncEngine` publishes no import progress or backlog depth, so after a
  /// local wipe the vault can look empty for minutes with no way to tell a
  /// running import from a finished one. Counting both sides on demand is the
  /// cheapest signal that separates them.
  struct VaultRecordCountSheet: View {

    let descriptor: VaultDescriptor
    let onClose: @MainActor @Sendable () -> Void

    @Environment(JournalVaultRuntime.self) private var vaultRuntime

    @State private var local: VaultLocalSyncCounts?
    @State private var localErrorMessage: String?
    @State private var cloud: VaultCloudRecordCountState = .fetching

    var body: some View {
      NavigationStack {
        VaultRecordCountList(
          local: local,
          localErrorMessage: localErrorMessage,
          cloud: cloud
        )
        .navigationTitle(descriptor.title)
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Done", action: onClose)
          }

          ToolbarItem(placement: .primaryAction) {
            Button {
              Task { await reload() }
            } label: {
              Image(systemName: "arrow.clockwise")
            }
            .accessibilityLabel("Refresh Counts")
            .disabled(cloud.isFetching)
          }
        }
      }
      .task { await reload() }
    }

    private func reload() async {
      // The local read is immediate, so show it before the CloudKit round trip
      // rather than holding both behind one spinner.
      do {
        local = try vaultRuntime.localSyncCounts(for: descriptor.vaultID)
        localErrorMessage = nil
      } catch {
        local = nil
        localErrorMessage = error.localizedDescription
      }

      cloud = .fetching
      do {
        cloud = .loaded(try await vaultRuntime.cloudRecordCounts(for: descriptor.vaultID))
      } catch is CancellationError {
        return
      } catch {
        cloud = .failed(error.localizedDescription)
      }
    }
  }

  /// Outcome of the on-demand CloudKit count for one vault zone.
  private enum VaultCloudRecordCountState {
    case fetching
    case loaded(VaultRecordCountSnapshot)
    case failed(String)

    var isFetching: Bool {
      switch self {
      case .fetching:
        true
      case .loaded, .failed:
        false
      }
    }

    var snapshot: VaultRecordCountSnapshot? {
      switch self {
      case .loaded(let snapshot):
        snapshot
      case .fetching, .failed:
        nil
      }
    }
  }

  private struct VaultRecordCountList: View {

    let local: VaultLocalSyncCounts?
    let localErrorMessage: String?
    let cloud: VaultCloudRecordCountState

    var body: some View {
      Form {
        Section {
          ForEach(VaultRecordType.allCases, id: \.self) { recordType in
            VaultRecordCountRow(
              title: recordType.rawValue,
              localCount: local?.records.count(of: recordType),
              cloudCount: cloud.snapshot?.count(of: recordType)
            )
          }

          if let otherRecordCount = cloud.snapshot?.otherRecordCount, otherRecordCount > 0 {
            VaultRecordCountRow(
              title: "Other (share)",
              localCount: nil,
              cloudCount: otherRecordCount
            )
          }
        } header: {
          Text("Local / iCloud")
        } footer: {
          Text("Counts are read on demand: local rows from SwiftData, iCloud records straight from the vault zone.")
        }
        .settingsListRowBackground()

        Section {
          VaultRecordCountRow(
            title: "Total",
            localCount: local?.records.total,
            cloudCount: cloud.snapshot?.total
          )

          if let remainingCount {
            LabeledContent("Not Imported Yet", value: remainingCount.formatted())
          }

          if let pendingMutationCount = local?.pendingMutationCount {
            LabeledContent("Pending Uploads", value: pendingMutationCount.formatted())
          }
        } header: {
          Text("Summary")
        }
        .settingsListRowBackground()

        switch cloud {
        case .fetching:
          Section {
            HStack(spacing: 8) {
              ProgressView()
              Text("Counting iCloud records…")
                .foregroundStyle(.secondary)
            }
          }
          .settingsListRowBackground()

        case .failed(let message):
          Section {
            Text(message)
              .foregroundStyle(.secondary)
          } header: {
            Text("iCloud Error")
          }
          .settingsListRowBackground()

        case .loaded:
          EmptyView()
        }

        if let localErrorMessage {
          Section {
            Text(localErrorMessage)
              .foregroundStyle(.secondary)
          } header: {
            Text("Local Error")
          }
          .settingsListRowBackground()
        }
      }
      .scrollContentBackground(.hidden)
      .background(.background)
    }

    /// Records CloudKit holds that this device has not imported yet. `nil` until
    /// both sides are known, and hidden when the local store is ahead because a
    /// pending upload has not been acknowledged.
    private var remainingCount: Int? {
      guard let local, let snapshot = cloud.snapshot else { return nil }
      let remaining = snapshot.total - local.records.total
      return remaining > 0 ? remaining : nil
    }
  }

  private struct VaultRecordCountRow: View {

    let title: String
    let localCount: Int?
    let cloudCount: Int?

    var body: some View {
      LabeledContent(title) {
        Text("\(text(for: localCount)) / \(text(for: cloudCount))")
          .monospacedDigit()
      }
    }

    private func text(for count: Int?) -> String {
      count?.formatted() ?? "—"
    }
  }

  #Preview("Importing") {
    VaultRecordCountList(
      local: VaultLocalSyncCounts(
        records: VaultRecordCountSnapshot(
          countsByRecordType: [.vaultInfo: 1, .card: 12, .cardEdge: 12]
        ),
        pendingMutationCount: 0
      ),
      localErrorMessage: nil,
      cloud: .loaded(
        VaultRecordCountSnapshot(
          countsByRecordType: [
            .vaultInfo: 1, .card: 84, .cardEdge: 84, .attachment: 30,
            .attachmentResource: 30, .activity: 84,
          ],
          otherRecordCount: 1
        )
      )
    )
  }

  #Preview("Counting") {
    VaultRecordCountList(
      local: VaultLocalSyncCounts(
        records: VaultRecordCountSnapshot(countsByRecordType: [.vaultInfo: 1, .card: 12]),
        pendingMutationCount: 3
      ),
      localErrorMessage: nil,
      cloud: .fetching
    )
  }

#endif
