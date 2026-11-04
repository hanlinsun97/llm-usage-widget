import AppKit

@main struct MenuBarChecks {
    static func main() {
        let now = Date(timeIntervalSince1970: 1800000000)
        let formatter = ISO8601DateFormatter()
        func row(_ id: String, _ value: Double, state: String = "ok", reset: Double = 3600, age: Double = 0) -> [String: Any] {
            ["id": id, "state": state, "weekly": ["remaining": value, "resetsAt": formatter.string(from: now.addingTimeInterval(reset))],
             "measuredAt": formatter.string(from: now.addingTimeInterval(-age))]
        }
        let values = MenuUsageRing.make(rows: [row("claude", 50), row("codex_su", 100), row("codex", 0), row("codex_iu", 42)], now: now)
        precondition(values.map(\.id) == ["codex", "codex_iu", "codex_su", "claude"])
        precondition(values.map(\.remaining) == [0, 42, 100, 50])
        precondition(values.allSatisfy { $0.state == .current })
        precondition(MenuUsageRing.make(rows: [], now: now).allSatisfy { $0.remaining == nil })
        precondition(MenuUsageRing.make(rows: [row("codex", 100, state: "signIn")], now: now)[0].state == .signIn)
        precondition(MenuUsageRing.make(rows: [row("codex", 100, reset: 0)], now: now)[0].state == .expired)
        // Re-evaluating the unchanged snapshot after a reset cannot leave a full ring.
        precondition(MenuUsageRing.make(rows: [row("codex", 100)], now: now.addingTimeInterval(3601))[0].remaining == nil)
        // Long after a reset, or from a stale reading, the summary says "No data", not "Updating".
        precondition(MenuUsageRing.make(rows: [row("codex", 100, reset: -1000)], now: now)[0].state == .unavailable)
        precondition(MenuUsageRing.make(rows: [row("codex", 100, reset: -60, age: 1000)], now: now)[0].summary.hasSuffix("No data"))
        precondition(MenuUsageRing.make(rows: [row("codex", 100, reset: -60)], now: now)[0].summary.hasSuffix("Updating"))
        precondition(MenuUsageRing.make(rows: [row("codex", 12, age: 901)], now: now)[0].state == .stale)
        precondition(MenuUsageRing.make(rows: [row("codex", 12, age: 600)], now: now)[0].state == .current)
        precondition(MenuUsageRing.make(rows: [row("codex", 12, state: "stale")], now: now)[0].summary.contains("cached"))
        precondition(MenuUsageRing.make(rows: [row("codex", .nan)], now: now)[0].remaining == nil)
        precondition(MenuUsageRing.make(rows: [row("codex", 123)], now: now)[0].remaining == 100)
        precondition(MenuUsageRing.make(rows: [row("codex", -10)], now: now)[0].remaining == 0)
        precondition(MenuUsageRing.date("2026-11-04T14:45:00.125Z") != nil)
        let image = MenuUsageRing.image(values)
        precondition(image.size == NSSize(width: 96, height: 22) && image.isTemplate)
        // Accounts come from accounts.json: order, ring labels and image width follow the list.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("llm-accounts-\(getpid())")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bad = folder.appendingPathComponent("bad.json"), dup = folder.appendingPathComponent("dup.json"), good = folder.appendingPathComponent("good.json")
        try? Data("not json".utf8).write(to: bad)
        try? Data(#"[{"id":"a","name":"A"},{"id":"a","name":"B"}]"#.utf8).write(to: dup)
        try? Data(#"[{"id":"glm","name":"GLM","label":"Z"},{"id":"claude","name":"Claude","menuLabel":"C","icon":"claude"}]"#.utf8).write(to: good)
        let loaded = Account.load(from: [folder.appendingPathComponent("missing.json"), bad, dup, good])
        precondition(loaded.map(\.id) == ["glm", "claude"] && loaded[0].displayName == "GLM Z" && loaded[1].displayName == "Claude")
        precondition(loaded[0].chatgptProfile == nil && Account.load(from: [bad]).isEmpty)
        let bundled = Account.load(from: [URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "accounts.json")])
        precondition(!bundled.isEmpty && Set(bundled.map(\.id)).count == bundled.count, "bundled accounts.json must load")
        // Own icons: plain SVG accepted; scripts, handlers and links rejected.
        let svgOK = folder.appendingPathComponent("ok.svg"), svgBad = folder.appendingPathComponent("bad.svg"), svgHandler = folder.appendingPathComponent("h.svg")
        try? Data(#"<svg viewBox="0 0 1 1"><path d="M0 0h1"/></svg>"#.utf8).write(to: svgOK)
        try? Data(#"<svg><script>alert(1)</script></svg>"#.utf8).write(to: svgBad)
        try? Data(#"<svg onload ="x()"></svg>"#.utf8).write(to: svgHandler)
        precondition(Account.iconSVG(file: "ok.svg", base: folder) != nil && Account.iconSVG(file: svgBad.path, base: folder) == nil && Account.iconSVG(file: "h.svg", base: folder) == nil && Account.iconSVG(file: "missing.svg", base: folder) == nil)
        MenuUsageRing.accounts = loaded.map { ($0.id, $0.menuLabel ?? $0.label ?? String($0.name.prefix(1)), $0.displayName) }
        let custom = MenuUsageRing.make(rows: [row("claude", 40), row("glm", 70)], now: now)
        precondition(custom.map(\.id) == ["glm", "claude"] && custom.map(\.label) == ["Z", "C"] && custom[0].summary == "GLM Z: 70% weekly left")
        precondition(MenuUsageRing.image(custom).size.width == 48)
        try? FileManager.default.removeItem(at: folder)
        print("PASS: accounts.json loading (missing/invalid/duplicate files skipped, bundled list), own SVG icons (safe only), custom order, labels and width")
        print("PASS: fixed four-account order, real zero/full, unavailable/login/expiry, unchanged-data expiry, stale cache, finite values, bounds, fractional dates and template size")
    }
}
