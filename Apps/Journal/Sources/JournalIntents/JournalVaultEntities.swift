import AppIntents
import Foundation
import JournalVault

/// A lightweight, sendable description of a vault that accepts new posts.
///
/// This is the non-App-Intents model used by posting services and Share UI.
/// Keeping it separate from `VaultDescriptor` prevents those callers from
/// accidentally treating read-only vaults as valid posting destinations.
public struct JournalWritableVault: Identifiable, Hashable, Sendable {
  /// Stable identity of the destination vault.
  public let id: VaultID

  /// User-facing vault title from the shared catalog.
  public let title: String

  public init(id: VaultID, title: String) {
    self.id = id
    self.title = title
  }
}

/// App Intents representation of any Journal vault.
///
/// Widget configuration uses this entity because a read-only shared vault is
/// still a valid source for reading and rendering a timeline.
public struct JournalVaultEntity: AppEntity, Identifiable, Hashable {
  public let id: String
  public let title: String
  public let icon: VaultIcon

  public static let typeDisplayRepresentation: TypeDisplayRepresentation = "Vault"
  public static let defaultQuery = JournalVaultEntityQuery()

  public var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(title: "\(displayTitle)")
  }

  public init(descriptor: VaultDescriptor) {
    id = descriptor.vaultID.uuidString
    title = descriptor.title
    icon = descriptor.icon
  }

  public init(id: String, title: String, icon: VaultIcon = .default) {
    self.id = id
    self.title = title
    self.icon = icon
  }

  /// Typed vault identity, or `nil` if persisted App Intents state is corrupt.
  public var vaultID: VaultID? {
    VaultID(uuidString: id)
  }

  private var displayTitle: String {
    let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmedTitle.isEmpty ? String(localized: "Untitled Vault") : trimmedTitle
  }
}

/// Query used by read-oriented system surfaces such as the latest-note widget.
///
/// Every invocation opens only the lightweight App Group catalog. It never
/// opens a vault content store or starts CloudKit synchronization.
public struct JournalVaultEntityQuery: EntityQuery, EntityStringQuery {
  public init() {}

  public func entities(for identifiers: [JournalVaultEntity.ID]) async throws -> [JournalVaultEntity] {
    let identifierSet = Set(identifiers)
    return try await JournalVaultCatalogReader.allEntities()
      .filter { identifierSet.contains($0.id) }
  }

  public func suggestedEntities() async throws -> [JournalVaultEntity] {
    try await JournalVaultCatalogReader.allEntities()
  }

  public func defaultResult() async -> JournalVaultEntity? {
    try? await JournalVaultCatalogReader.allEntities().first
  }

  public func entities(matching string: String) async throws -> [JournalVaultEntity] {
    let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
    guard query.isEmpty == false else {
      return try await suggestedEntities()
    }

    return try await JournalVaultCatalogReader.allEntities()
      .filter { $0.title.localizedCaseInsensitiveContains(query) }
  }
}

/// App Intents representation of a vault that currently permits writes.
///
/// Posting intents use this distinct type so Shortcuts and Control Center never
/// offer a read-only collaboration vault as an actionable destination.
public struct JournalWritableVaultEntity: AppEntity, Identifiable, Hashable {
  public let id: String
  public let title: String
  public let icon: VaultIcon

  public static let typeDisplayRepresentation: TypeDisplayRepresentation = "Writable Vault"
  public static let defaultQuery = JournalWritableVaultEntityQuery()

  public var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(title: "\(displayTitle)")
  }

  public init(descriptor: VaultDescriptor) {
    id = descriptor.vaultID.uuidString
    title = descriptor.title
    icon = descriptor.icon
  }

  public init(vault: JournalWritableVault, icon: VaultIcon = .default) {
    id = vault.id.uuidString
    title = vault.title
    self.icon = icon
  }

  public init(id: String, title: String, icon: VaultIcon = .default) {
    self.id = id
    self.title = title
    self.icon = icon
  }

  /// Typed vault identity, or `nil` if persisted App Intents state is corrupt.
  public var vaultID: VaultID? {
    VaultID(uuidString: id)
  }

  /// Non-App-Intents descriptor for posting services and extension UI.
  public var writableVault: JournalWritableVault? {
    vaultID.map { JournalWritableVault(id: $0, title: title) }
  }

  private var displayTitle: String {
    let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmedTitle.isEmpty ? String(localized: "Untitled Vault") : trimmedTitle
  }
}

/// Query used by system actions that create Journal content.
///
/// Unlike `JournalVaultEntityQuery`, this query excludes vaults whose catalog
/// permission is `.readOnly`. Its default is the most recent successful Share
/// destination; it deliberately does not fall back to the first writable vault.
public struct JournalWritableVaultEntityQuery: EntityQuery, EntityStringQuery {
  public init() {}

  public func entities(
    for identifiers: [JournalWritableVaultEntity.ID]
  ) async throws -> [JournalWritableVaultEntity] {
    let identifierSet = Set(identifiers)
    return try await JournalVaultCatalogReader.writableEntities()
      .filter { identifierSet.contains($0.id) }
  }

  public func suggestedEntities() async throws -> [JournalWritableVaultEntity] {
    try await JournalVaultCatalogReader.writableEntities()
  }

  public func defaultResult() async -> JournalWritableVaultEntity? {
    guard let preferredVaultID = try? JournalQuickCapturePreferences().selectedVaultID() else {
      return nil
    }

    return try? await JournalVaultCatalogReader.writableEntities()
      .first { $0.id == preferredVaultID.uuidString }
  }

  public func entities(matching string: String) async throws -> [JournalWritableVaultEntity] {
    let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
    guard query.isEmpty == false else {
      return try await suggestedEntities()
    }

    return try await JournalVaultCatalogReader.writableEntities()
      .filter { $0.title.localizedCaseInsensitiveContains(query) }
  }
}

private enum JournalVaultCatalogReader {
  static func allEntities() async throws -> [JournalVaultEntity] {
    try await descriptors().map(JournalVaultEntity.init)
  }

  static func writableEntities() async throws -> [JournalWritableVaultEntity] {
    try await descriptors()
      .filter { $0.permission != .readOnly }
      .map(JournalWritableVaultEntity.init)
  }

  private static func descriptors() async throws -> [VaultDescriptor] {
    try await MainActor.run {
      let layout = try VaultStoreLayout.appGroup()
      let catalog = try VaultCatalogStore.open(layout: layout)
      return try catalog.vaultDescriptors()
    }
  }
}
