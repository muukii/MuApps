import CoreData
import JournalModel
import SwiftData
import SwiftUI

struct SyncDetailsView: View {

  @Environment(\.modelContext) private var modelContext
  @State private var isRefreshing = false

  var body: some View {
    let monitor = SyncStatusMonitor.shared

    Form {
      SyncOverviewSection(summary: monitor.summary)
      SyncAccountSection(detail: monitor.accountDetail)
      SyncRowMirroringSection(detail: monitor.rowSyncDetail)
      SyncMediaFilesSection(
        snapshot: monitor.mediaSyncSnapshot,
        availability: monitor.localMediaAvailability,
        availabilityErrorMessage: monitor.localMediaErrorMessage
      )
      SyncRecentEventsSection(events: monitor.recentMirroringEvents)
    }
    .navigationTitle("iCloud Sync")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button {
          Task { await refresh(showSpinner: true) }
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        .disabled(isRefreshing)
      }
    }
    .task {
      await refresh(showSpinner: true)
      while Task.isCancelled == false {
        do {
          try await Task.sleep(for: .seconds(3))
        } catch {
          break
        }
        await refresh(showSpinner: false)
      }
    }
  }

  @MainActor
  private func refresh(showSpinner: Bool) async {
    if showSpinner {
      isRefreshing = true
    }
    defer {
      if showSpinner {
        isRefreshing = false
      }
    }
    await SyncStatusMonitor.shared.refreshDetails(in: modelContext)
  }
}

private struct SyncOverviewSection: View {

  let summary: SyncStatusMonitor.Summary

  var body: some View {
    Section {
      SyncStatusRow(summary: summary)
    } footer: {
      Text("Status combines SwiftData row mirroring and the separate media-file sync.")
    }
  }
}

private struct SyncAccountSection: View {

  let detail: SyncStatusMonitor.AccountDetail

  var body: some View {
    Section("Account") {
      LabeledContent("Status", value: detail.status)
      LabeledContent("Available") {
        BooleanValueText(value: detail.isAvailable)
      }
      LabeledContent("Container", value: "iCloud.app.muukii.journal")
    }
  }
}

private struct SyncRowMirroringSection: View {

  let detail: SyncStatusMonitor.RowSyncDetail

  var body: some View {
    Section {
      SyncActivityRow(title: "Setup", isActive: detail.setupInProgress)
      SyncActivityRow(title: "Download", isActive: detail.importInProgress)
      SyncActivityRow(title: "Upload", isActive: detail.exportInProgress)
      LabeledContent("Last completed") {
        OptionalDateText(date: detail.lastSyncedAt)
      }
      if let lastErrorMessage = detail.lastErrorMessage {
        LabeledContent("Last error") {
          Text(lastErrorMessage)
            .foregroundStyle(.red)
        }
      }
    } header: {
      Text("Journal Rows")
    } footer: {
      Text("Row events come from SwiftData's CloudKit mirroring. They are batch events, not a percentage.")
    }
  }
}

private struct SyncMediaFilesSection: View {

  let snapshot: MediaSyncEngine.Snapshot
  let availability: JournalStore.LocalMediaAvailability
  let availabilityErrorMessage: String?

  var body: some View {
    Section {
      SyncActivityRow(title: "Fetch", isActive: snapshot.isFetchingChanges)
      SyncActivityRow(title: "Send", isActive: snapshot.isSendingChanges)

      LabeledContent("Pending uploads") {
        IntegerValueText(value: snapshot.pendingUploadCount, isWarning: snapshot.pendingUploadCount > 0)
      }
      LabeledContent("Pending deletes") {
        IntegerValueText(value: snapshot.pendingDeleteCount, isWarning: snapshot.pendingDeleteCount > 0)
      }
      LabeledContent("Pending zone changes") {
        IntegerValueText(
          value: snapshot.pendingDatabaseChangeCount,
          isWarning: snapshot.pendingDatabaseChangeCount > 0
        )
      }
      LabeledContent("Known cloud files") {
        IntegerValueText(value: snapshot.uploadedRecordCount)
      }

      LabeledContent("Attachment rows") {
        IntegerValueText(value: availability.attachmentCount)
      }
      LabeledContent("Local files") {
        IntegerValueText(value: availability.localFileCount)
      }
      LabeledContent("Missing local files") {
        IntegerValueText(value: availability.missingFileCount, isWarning: availability.missingFileCount > 0)
      }

      LabeledContent("Last uploaded") {
        OptionalDateText(date: snapshot.lastUploadedAt)
      }
      LabeledContent("Last downloaded") {
        OptionalDateText(date: snapshot.lastDownloadedAt)
      }
      LabeledContent("Last deleted") {
        OptionalDateText(date: snapshot.lastDeletedAt)
      }

      LabeledContent("Fetched files") {
        IntegerValueText(value: snapshot.lastFetchedModificationCount)
      }
      LabeledContent("Fetched deletes") {
        IntegerValueText(value: snapshot.lastFetchedDeletionCount)
      }
      LabeledContent("Saved files") {
        IntegerValueText(value: snapshot.lastSavedRecordCount)
      }
      LabeledContent("Failed saves") {
        IntegerValueText(value: snapshot.lastFailedRecordSaveCount, isWarning: snapshot.lastFailedRecordSaveCount > 0)
      }
      LabeledContent("Deleted files") {
        IntegerValueText(value: snapshot.lastDeletedRecordCount)
      }
      LabeledContent("Failed deletes") {
        IntegerValueText(
          value: snapshot.lastFailedRecordDeleteCount,
          isWarning: snapshot.lastFailedRecordDeleteCount > 0
        )
      }

      if let availabilityErrorMessage {
        LabeledContent("Availability error") {
          Text(availabilityErrorMessage)
            .foregroundStyle(.red)
        }
      }
      if let lastErrorMessage = snapshot.lastErrorMessage {
        LabeledContent("Last error") {
          Text(lastErrorMessage)
            .foregroundStyle(.red)
        }
      }
    } header: {
      Text("Media Files")
    } footer: {
      Text("Media files sync separately from rows. A missing local file means the Attachment row exists, but the file is not present on this device yet.")
    }
  }
}

private struct SyncRecentEventsSection: View {

  let events: [SyncStatusMonitor.MirroringEvent]

  var body: some View {
    Section {
      if events.isEmpty {
        Text("No row sync events observed since launch.")
          .foregroundStyle(.secondary)
      } else {
        ForEach(events) { event in
          SyncEventRow(event: event)
        }
      }
    } header: {
      Text("Recent Row Events")
    } footer: {
      Text("Only events observed while this app process is running are listed.")
    }
  }
}

private struct SyncEventRow: View {

  let event: SyncStatusMonitor.MirroringEvent

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Label(event.typeName, systemImage: event.symbolName)
          .foregroundStyle(.primary)

        Spacer(minLength: 0)

        Text(event.statusName)
          .font(.caption)
          .fontWeight(.medium)
          .foregroundStyle(event.statusStyle)
      }

      Text(event.storeIdentifier)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)

      VStack(alignment: .leading, spacing: 2) {
        EventDateLine(title: "Started", date: event.startDate)
        if let endDate = event.endDate {
          EventDateLine(title: "Ended", date: endDate)
        }
      }

      if let errorMessage = event.errorMessage {
        Text(errorMessage)
          .font(.caption)
          .foregroundStyle(.red)
      }
    }
    .padding(.vertical, 4)
  }
}

private struct EventDateLine: View {

  let title: String
  let date: Date

  var body: some View {
    HStack(spacing: 6) {
      Text(title)
        .foregroundStyle(.secondary)
      Text(date, format: .dateTime.month().day().hour().minute().second())
        .monospacedDigit()
    }
    .font(.caption)
  }
}

private struct SyncActivityRow: View {

  let title: String
  let isActive: Bool

  var body: some View {
    LabeledContent(title) {
      Text(isActive ? "Running" : "Idle")
        .foregroundStyle(isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
    }
  }
}

private struct BooleanValueText: View {

  let value: Bool

  var body: some View {
    Text(value ? "Yes" : "No")
      .foregroundStyle(value ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
  }
}

private struct OptionalDateText: View {

  let date: Date?

  var body: some View {
    if let date {
      Text(date, format: .dateTime.month().day().hour().minute().second())
        .monospacedDigit()
    } else {
      Text("Not observed")
        .foregroundStyle(.secondary)
    }
  }
}

private struct IntegerValueText: View {

  let value: Int
  var isWarning = false

  var body: some View {
    Text(value, format: .number)
      .monospacedDigit()
      .foregroundStyle(isWarning ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
  }
}

private extension SyncStatusMonitor.MirroringEvent {

  var typeName: String {
    switch type {
    case .setup: "Setup"
    case .`import`: "Download"
    case .export: "Upload"
    @unknown default: "Unknown"
    }
  }

  var symbolName: String {
    switch type {
    case .setup: "gearshape"
    case .`import`: "arrow.down.icloud"
    case .export: "arrow.up.icloud"
    @unknown default: "questionmark.circle"
    }
  }

  var statusName: String {
    if isActive {
      return "Running"
    }
    return succeeded ? "Succeeded" : "Failed"
  }

  var statusStyle: AnyShapeStyle {
    if isActive {
      return AnyShapeStyle(.tint)
    }
    return succeeded ? AnyShapeStyle(.green) : AnyShapeStyle(.red)
  }
}
