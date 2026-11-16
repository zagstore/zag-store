import Foundation

/// Presentation only: channel identifiers and persisted preference values are untouched.
enum ZagUpdateChannelPresentation {
    static func title(for identifier: String) -> String {
        switch identifier {
        case "beta": return "Beta"
        case "nightly": return "Nightly"
        default: return "Stable"
        }
    }
}

/// Foundation parses Markdown; presentation intents retain the block/list structure
/// while native attributed text retains bold, emphasis and safe web links.
struct ZagUpdateReleaseNotes {
    struct Block: Identifiable {
        let id: Int
        var text: AttributedString
        let heading: Int?
        let marker: String?
    }
    let blocks: [Block]

    init(markdown: String) {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible
        )
        let source = markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Release notes are not available for this update." : markdown
        guard let parsed = try? AttributedString(markdown: source, options: options) else {
            blocks = [Block(id: 0, text: AttributedString("Release notes could not be displayed. Use Learn More to read them."), heading: nil, marker: nil)]
            return
        }
        var result: [Block] = []
        for run in parsed.runs {
            let components = run.presentationIntent?.components ?? []
            let leaf = components.first
            let id = leaf?.identity ?? 0
            var heading: Int?
            var ordinal: Int?
            var ordered = false
            for component in components {
                switch component.kind {
                case .header(let level): heading = level
                case .listItem(let value): ordinal = value
                case .orderedList: ordered = true
                default: break
                }
            }
            var text = AttributedString(parsed[run.range])
            text.presentationIntent = nil
            if let url = text.link, !Self.isSafeWebURL(url) { text.link = nil }
            if result.last?.id == id {
                result[result.count - 1].text.append(text)
            } else {
                result.append(Block(id: id, text: text, heading: heading,
                                    marker: ordinal.map { ordered ? "\($0)." : "•" }))
            }
        }
        blocks = result
    }

    /// Start with meaningful descriptive content instead of repeating the version heading.
    var preview: AttributedString {
        let content = blocks.filter { $0.heading == nil }
        var result = AttributedString()
        for block in content.isEmpty ? blocks : content {
            if !result.characters.isEmpty { result.append(AttributedString("\n")) }
            if let marker = block.marker { result.append(AttributedString(marker + " ")) }
            result.append(block.text)
        }
        return result
    }

    /// The card already presents this exact release identity. Keep all other
    /// headings/content in order; never insert a duplicate title above the preview.
    func inlineBlocks(version: String?, build: String?) -> [Block] {
        guard let version, let build, let first = blocks.first, first.heading == 1 else { return blocks }
        let title = String(first.text.characters).lowercased()
        let identity = "zag store \(version.lowercased())"
        let suffix = " (build \(build.lowercased()))"
        let duplicateTitles = [identity + suffix,
                               identity + " — beta \(build.lowercased())" + suffix,
                               identity + " — nightly \(build.lowercased())" + suffix]
        guard duplicateTitles.contains(title), blocks.count > 1 else { return blocks }
        return Array(blocks.dropFirst())
    }

    static func isSafeWebURL(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ["https", "http"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil else { return false }
        return true
    }
}
