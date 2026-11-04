import AppKit

/// The same accounts in the same order as the desktop (set from accounts.json); never infer zero
/// allowance from a missing, expired or unauthenticated reading.
struct MenuUsageRing {
    enum State: String { case current, stale, expired, signIn, unavailable }
    let id: String
    let label: String
    let name: String
    let remaining: Double?
    let state: State

    /// (id, label inside the ring, name in tooltips). Replaced at launch from accounts.json.
    static var accounts: [(String, String, String)] = [("codex", "ME", "Codex ME"), ("codex_iu", "IU", "Codex IU"),
                           ("codex_su", "SU", "Codex SU"), ("claude", "C", "Claude")]

    static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = parser.date(from: text) { return date }
        parser.formatOptions = [.withInternetDateTime]
        return parser.date(from: text)
    }

    static func make(rows: [[String: Any]], now: Date = Date()) -> [MenuUsageRing] {
        accounts.map { id, label, name in
            func ring(_ remaining: Double?, _ state: State) -> MenuUsageRing {
                MenuUsageRing(id: id, label: label, name: name, remaining: remaining, state: state)
            }
            guard let row = rows.first(where: { $0["id"] as? String == id }) else { return ring(nil, .unavailable) }
            let state = row["state"] as? String
            if state == "signIn" { return ring(nil, .signIn) }
            guard state == "ok" || state == "stale",
                  let weekly = row["weekly"] as? [String: Any],
                  let value = weekly["remaining"] as? Double, value.isFinite else { return ring(nil, .unavailable) }
            // Matches the widget: readings older than 15 minutes count as stale.
            let fresh = date(row["measuredAt"]).map { now.timeIntervalSince($0) <= 900 } ?? false
            // "Updating" only briefly after a reset of a fresh reading; otherwise there is no data.
            if let reset = date(weekly["resetsAt"]), reset <= now {
                return ring(nil, fresh && state != "stale" && now.timeIntervalSince(reset) < 900 ? .expired : .unavailable)
            }
            return ring(min(100, max(0, value)), state == "stale" || !fresh ? .stale : .current)
        }
    }

    var summary: String {
        guard let remaining else {
            let reason = state == .signIn ? "Sign in" : state == .expired ? "Updating" : "No data"
            return "\(name): \(reason)"
        }
        let number = remaining.rounded() == remaining ? String(format: "%.0f", remaining) : String(format: "%.1f", remaining)
        return "\(name): \(number)% weekly left\(state == .stale ? " (cached)" : "")"
    }

    /// Template rendering keeps the tiny rings legible on both light/dark menu bars.
    static func image(_ rings: [MenuUsageRing]) -> NSImage {
        let image = NSImage(size: NSSize(width: CGFloat(max(1, rings.count)) * 24, height: 22), flipped: false) { _ in
            for (index, ring) in rings.enumerated() {
                let center = NSPoint(x: 12 + CGFloat(index) * 24, y: 11)
                let rect = NSRect(x: center.x - 8, y: center.y - 8, width: 16, height: 16)
                let track = NSBezierPath(ovalIn: rect)
                track.lineWidth = 1.8
                if ring.remaining == nil { track.setLineDash([2, 2], count: 2, phase: 0) }
                NSColor.black.withAlphaComponent(ring.remaining == nil ? 0.5 : 0.22).setStroke()
                track.stroke()
                if let value = ring.remaining, value > 0 {
                    let arc = NSBezierPath()
                    if value >= 100 { arc.appendOval(in: rect) }
                    else { arc.appendArc(withCenter: center, radius: 8, startAngle: 90, endAngle: 90 - CGFloat(value) * 3.6, clockwise: true) }
                    arc.lineWidth = 1.8
                    arc.lineCapStyle = .round
                    NSColor.black.withAlphaComponent(ring.state == .stale ? 0.5 : 1).setStroke()
                    arc.stroke()
                }
                let text = ring.label as NSString
                let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 6.5, weight: .semibold), .foregroundColor: NSColor.black]
                let size = text.size(withAttributes: attributes)
                text.draw(at: NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2), withAttributes: attributes)
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
