import SwiftUI
import UniformTypeIdentifiers

/// Generic file values rendered by compact, detail, and export styles.
///
/// `displayName` comes from the card body, while `fileURL` points at the
/// primary `.file` attachment resource when it is locally available.
public struct FileContentSource: Hashable, Sendable {
  public let displayName: String
  public let fileURL: URL?
  public let contentType: String?
  public let byteSize: Int?

  public init(
    displayName: String,
    fileURL: URL? = nil,
    contentType: String? = nil,
    byteSize: Int? = nil
  ) {
    self.displayName = displayName
    self.fileURL = fileURL
    self.contentType = contentType
    self.byteSize = byteSize
  }
}

/// Describes a persisted file without decoding its arbitrary bytes.
struct FileContentView: View {

  /// Visual treatment owned by generic file content.
  struct Style {
    let preset: EntryContentStyle

    init(_ preset: EntryContentStyle) {
      self.preset = preset
    }

    var spacing: CGFloat {
      switch preset {
      case .composer, .overview:
        return 10
      case .detail:
        return 14
      case .share:
        return 28
      }
    }

    var iconFont: Font {
      switch preset {
      case .composer, .overview:
        return .system(size: 34, weight: .regular)
      case .detail:
        return .system(size: 52, weight: .regular)
      case .share:
        return .system(size: 112, weight: .regular)
      }
    }

    var titleFont: Font {
      switch preset {
      case .composer, .overview, .detail:
        return .headline.weight(.semibold)
      case .share:
        return .system(size: 52, weight: .bold)
      }
    }

    var titleLineLimit: Int {
      switch preset {
      case .composer, .overview:
        return 3
      case .detail, .share:
        return 4
      }
    }

    var metadataFont: Font {
      preset == .share ? .system(size: 26, weight: .medium) : .caption
    }

    var minimumScaleFactor: CGFloat {
      preset == .share ? 0.62 : 0.8
    }

    var padding: CGFloat {
      preset == .share ? 36 : 16
    }

    var showsUnavailableState: Bool {
      preset == .share
    }

    var fillsAvailableHeight: Bool {
      preset == .share
    }

    var minimumHeight: CGFloat? {
      preset == .detail ? 120 : nil
    }
  }

  let file: FileContentSource
  let style: Style

  var body: some View {
    VStack(spacing: style.spacing) {
      Image(systemName: "doc")
        .font(style.iconFont)
        .foregroundStyle(.secondary)

      Text(displayName)
        .font(style.titleFont)
        .lineLimit(style.titleLineLimit)
        .multilineTextAlignment(.center)
        .minimumScaleFactor(style.minimumScaleFactor)

      if metadata.isEmpty == false {
        Text(metadata.joined(separator: " · "))
          .font(style.metadataFont)
          .foregroundStyle(.secondary)
          .lineLimit(2)
          .multilineTextAlignment(.center)
      }

      if style.showsUnavailableState, file.fileURL == nil {
        Label("File unavailable", systemImage: "icloud.slash")
          .font(.system(size: 24, weight: .medium))
          .foregroundStyle(.secondary)
      }
    }
    .padding(style.padding)
    .frame(
      maxWidth: .infinity,
      maxHeight: style.fillsAvailableHeight ? .infinity : nil,
      alignment: .center
    )
    .accessibilityElement(children: .combine)
  }

  private var displayName: String {
    let name = file.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    if name.isEmpty == false {
      return name
    }

    if let fileURL = file.fileURL,
      fileURL.lastPathComponent.isEmpty == false
    {
      return fileURL.lastPathComponent
    }

    return String(localized: "File")
  }

  private var metadata: [String] {
    var values: [String] = []

    if let contentType = file.contentType,
      contentType.isEmpty == false
    {
      values.append(UTType(contentType)?.localizedDescription ?? contentType)
    }

    if let byteSize = file.byteSize {
      values.append(
        ByteCountFormatter.string(
          fromByteCount: Int64(byteSize),
          countStyle: .file
        )
      )
    }

    return values
  }
}

#Preview("File Content") {
  EntryContentPreviewCanvas {
    FileContentView(
      file: FileContentSource(
        displayName: "Field Notes.pdf",
        contentType: "application/pdf",
        byteSize: 2_400_000
      ),
      style: .init(.detail)
    )
  }
}
