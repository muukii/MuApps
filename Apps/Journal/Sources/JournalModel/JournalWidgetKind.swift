/// WidgetKit kind identifiers used by Journal extensions.
///
/// Keep these identifiers in the shared model module so the app target that
/// requests timeline reloads and the Widget extension that declares widgets
/// cannot drift apart.
public enum JournalWidgetKind {

  /// Home Screen widget that renders the most recently created Journal card.
  public static let latestNote = "LatestNoteWidget"
}
