/// WidgetKit kind identifiers used by Journal extensions.
///
/// Keep these identifiers in the vault module so the app target that requests
/// timeline reloads and the Widget extension that declares widgets cannot drift
/// apart while both are using `JournalVault` stores.
public enum JournalWidgetKind {

  /// Home Screen widget that renders the latest card from one configured vault.
  public static let latestNote = "LatestNoteWidget"
}
