import SwiftUI
import WidgetKit

/// Entry point for the Journal widget extension. New widgets are added to the
/// bundle's `body`; for now there is a single widget showing recent cards.
@main
struct JournalWidgetBundle: WidgetBundle {
  var body: some Widget {
    RecentCardsWidget()
  }
}
