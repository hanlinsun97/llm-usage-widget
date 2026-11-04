import Foundation

/// One entry of accounts.json. `id` matches the snapshot row id; `name` and `label` are shown
/// ("Codex" + "A"); `menuLabel` goes inside the menu-bar ring; `icon` is "codex"/"terminal",
/// "claude"/"asterisk" or absent; `iconFile` is a local SVG (relative to Application Support/LLMUsage)
/// that replaces the built-in icon; `chatgptProfile`/`codexHome` enable "Use in app" through
/// ~/.local/bin/codex-app-profile.
struct Account: Decodable {
    let id: String
    let name: String
    let label: String?
    let menuLabel: String?
    let icon: String?
    let iconFile: String?
    let chatgptProfile: String?
    let codexHome: String?
    var displayName: String { label.map { "\(name) \($0)" } ?? name }

    /// A user's own SVG icon, inlined into the page. Only a plain <svg> under 20 KB without scripts,
    /// event handlers, links or foreign objects is accepted.
    static func iconSVG(file: String, base: URL) -> String? {
        let url = file.hasPrefix("/") ? URL(fileURLWithPath: file) : base.appendingPathComponent(file)
        guard let data = try? Data(contentsOf: url), data.count < 20_000,
              let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              text.hasPrefix("<svg"), text.hasSuffix("</svg>") else { return nil }
        let lower = text.lowercased()
        let banned = ["<script", "javascript:", "<foreignobject", "href", "<iframe", "<!entity"]
        guard !banned.contains(where: lower.contains), lower.range(of: #"\son[a-z]+\s*="#, options: .regularExpression) == nil else { return nil }
        return text
    }

    /// The first readable, non-empty list with unique ids wins; an empty result keeps the snapshot's own rows.
    static func load(from urls: [URL]) -> [Account] {
        for url in urls {
            guard let data = try? Data(contentsOf: url), let list = try? JSONDecoder().decode([Account].self, from: data),
                  !list.isEmpty, Set(list.map(\.id)).count == list.count, list.allSatisfy({ !$0.id.isEmpty && !$0.name.isEmpty }) else { continue }
            return list
        }
        return []
    }
}
