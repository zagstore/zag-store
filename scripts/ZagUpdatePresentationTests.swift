import Foundation

@main struct UpdatePresentationTests {
    static func main() {
        var count = 0
        func check(_ condition: Bool, _ name: String) {
            precondition(condition, name)
            count += 1
            print("PASS: \(name)")
        }
        let sample = """
        # Zag Store 1.0.0 — Beta 3 (Build 3)

        Beta 3 introduces anonymous activity reporting and strengthens in-app updates.

        ## What's new

        - **Live Activity:** Anonymous foreground usage sessions.
        - **Improved self-updates:** Bounded-memory streaming.

        Read the [release page](https://example.com/releases#beta).
        """
        let notes = ZagUpdateReleaseNotes(markdown: sample)
        let plain = notes.blocks.map { String($0.text.characters) }.joined(separator: "\n")
        check(notes.blocks.contains { $0.heading == 1 }, "Markdown title retains heading semantics")
        check(notes.blocks.contains { $0.heading == 2 }, "Markdown subheading retains heading semantics")
        check(notes.blocks.filter { $0.marker == "•" }.count == 2, "bullet rows retain separate items")
        check(!plain.contains("# Zag") && !plain.contains("##") && !plain.contains("**") && !plain.contains("- **"), "structural Markdown is not exposed as raw text")
        check(notes.blocks.contains { block in block.text.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true } }, "bold remains native attributed text")
        check(String(notes.preview.characters).hasPrefix("Beta 3 introduces"), "preview starts with descriptive content rather than duplicate version heading")
        check(notes.blocks.contains { block in block.text.runs.contains { $0.link == URL(string: "https://example.com/releases#beta") } }, "safe release-note link retains destination and fragment")
        let ordered = ZagUpdateReleaseNotes(markdown: "1. First\n2. Second")
        check(ordered.blocks.map(\.marker) == ["1.", "2."], "ordered lists preserve order")
        let paragraphs = ZagUpdateReleaseNotes(markdown: "First paragraph.\n\nSecond paragraph.")
        check(paragraphs.blocks.count == 2, "paragraph boundaries survive parsing")
        let hardBreak = ZagUpdateReleaseNotes(markdown: "One  \nTwo")
        check(String(hardBreak.preview.characters).contains("\n"), "explicit line breaks survive parsing")
        let short = ZagUpdateReleaseNotes(markdown: "Small fixes.")
        check(short.blocks.count == 1 && String(short.preview.characters) == "Small fixes.", "short changelog stays complete and compact")
        let empty = ZagUpdateReleaseNotes(markdown: " \n")
        check(String(empty.preview.characters).contains("not available"), "empty notes have useful plain-language fallback")
        for url in ["https://example.com/release", "http://example.com/release", "HTTPS://example.com/release"] {
            check(ZagUpdateReleaseNotes.isSafeWebURL(URL(string: url)!), "web link allowed: \(url)")
        }
        for url in ["file:///private/data", "javascript:alert(1)", "zagstore://settings", "feather://install", "https://user:password@example.com", "mailto:someone@example.com"] {
            let link = URL(string: url)!
            check(!ZagUpdateReleaseNotes.isSafeWebURL(link), "unsafe/unrelated link rejected: \(url)")
            let unsafe = ZagUpdateReleaseNotes(markdown: "[Read more](\(url))")
            check(unsafe.blocks.allSatisfy { $0.text.runs.allSatisfy { $0.link == nil } }, "unsafe link attributes are removed")
        }
        check(ZagUpdateChannelPresentation.title(for: "stable") == "Stable", "stable identifier retains simple display title")
        check(ZagUpdateChannelPresentation.title(for: "off") == "Stable", "legacy stable preference retains simple display title")
        check(ZagUpdateChannelPresentation.title(for: "beta") == "Beta", "beta identifier retains simple display title")
        check(ZagUpdateChannelPresentation.title(for: "nightly") == "Nightly", "nightly identifier retains simple display title")
        print("SUCCESS: \(count) update presentation checks passed")
    }
}
