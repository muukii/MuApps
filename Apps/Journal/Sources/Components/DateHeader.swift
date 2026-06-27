import SwiftUI

struct DateView: View {
  let date: Date
  let locale: Locale

  init(date: Date = .now, locale: Locale = .current) {
    self.date = date
    self.locale = locale
  }

  var body: some View {
    Text(formattedDate)
      .font(.system(size: 20, weight: .semibold))
      .foregroundStyle(.secondary)
      .accessibilityLabel(accessibilityDate)
  }

  private var formattedDate: String {
    // Standard field selection — the system picks locale-appropriate order and
    // separators. en: "Sat, Jun 27", ja: "6月27日(土)", etc.
    date.formatted(
      .dateTime.weekday(.abbreviated).month(.abbreviated).day().locale(locale)
    )
  }

  private var accessibilityDate: String {
    // More verbose for VoiceOver
    date.formatted(.dateTime.weekday(.wide).month(.wide).day().locale(locale))
  }
}

// MARK: - Previews

#Preview("DateView") {
  VStack(spacing: 24) {
    DateView(date: Date(timeIntervalSince1970: 1_750_982_400))  // Sat Jun 27 2025 (UTC)
    DateView(
      date: Date(timeIntervalSince1970: 1_750_982_400),
      locale: Locale(identifier: "ja_JP")
    )
  }
  .padding()
}

#Preview("Locale matrix") {
  // Sat, Jun 27, 2025
  let date = Date(timeIntervalSince1970: 1_750_982_400)
  let locales: [Locale] = [
    Locale(identifier: "en_US"),
    Locale(identifier: "en_GB"),
    Locale(identifier: "ja_JP"),
    Locale(identifier: "fr_FR"),
    Locale(identifier: "de_DE"),
    Locale(identifier: "ko_KR"),
    Locale(identifier: "zh_Hans"),
    Locale(identifier: "ar_SA"),
  ]

  return ScrollView {
    VStack(alignment: .leading, spacing: 16) {
      ForEach(locales, id: \.identifier) { locale in
        HStack(alignment: .firstTextBaseline, spacing: 12) {
          Text(locale.identifier)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(width: 64, alignment: .leading)
          DateView(date: date, locale: locale)
            .environment(
              \.layoutDirection,
              locale.identifier.hasPrefix("ar") ? .rightToLeft : .leftToRight
            )
        }
        Divider()
      }
    }
    .padding()
  }
}
