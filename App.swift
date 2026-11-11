import AppKit
import WebKit

final class DragArea: NSView {
    // Desktop panels are usually inactive; their first click must begin the drag.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
}

final class DesktopPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKScriptMessageHandler, NSWindowDelegate, NSPopoverDelegate, NSMenuDelegate {
    var panel: DesktopPanel!
    var web: WKWebView!
    var item: NSStatusItem!
    var settingsMenu: NSMenu!
    var popover: NSPopover!
    var popoverWeb: WKWebView?
    var currentRows: [[String: Any]] = []
    var switchingRow: String?
    var settingsOpenedAt: Date?
    var timer: Timer?
    var lastData: Data?
    var refreshProcess: Process?
    var fetchTimer: Timer?
    var fetching = false
    var refetch = false
    var fetchCompletions: [() -> Void] = []
    var remoteData: Data?
    var sourceOK = true
    var switchProcess: Process?
    var glassSlider: NSSlider?
    var glassLabel: NSTextField?
    var captured = false
    var dragArea: DragArea?
    var layoutItems: [NSMenuItem] = []
    let previewMenu = CommandLine.arguments.contains("--preview-menu")
    var preview: Bool { CommandLine.arguments.contains("--preview") || previewMenu }
    let home = FileManager.default.homeDirectoryForCurrentUser
    let runtime = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/LLMUsage")
    // Accounts shown, in order, from accounts.json: the user's copy in Application Support wins over the
    // bundled example. Preview runs may point LLM_PREVIEW_ACCOUNTS at a fixed list.
    lazy var accounts: [Account] = Account.load(from: [
        preview ? ProcessInfo.processInfo.environment["LLM_PREVIEW_ACCOUNTS"].map { URL(fileURLWithPath: $0) } : nil,
        runtime.appendingPathComponent("accounts.json"),
        Bundle.main.url(forResource: "accounts", withExtension: "json")].compactMap { $0 })
    // Widget row id -> codex-app-profile name and its CODEX_HOME directory, for accounts the ChatGPT app can switch to.
    var profiles: [(row: String, name: String, dir: String)] {
        accounts.compactMap { a in a.chatgptProfile.map { (a.id, $0, a.codexHome ?? ".codex") } }
    }
    var accountsJSON: String {
        let list = accounts.map { a -> [String: Any] in
            var d: [String: Any] = ["id": a.id, "name": a.name]
            if let v = a.label { d["label"] = v }
            if let v = a.icon { d["icon"] = v }
            if let v = a.chatgptProfile { d["chatgptProfile"] = v }
            if let svg = a.iconFile.flatMap({ Account.iconSVG(file: $0, base: runtime) }) { d["iconSVG"] = svg }
            return d
        }
        return (try? JSONSerialization.data(withJSONObject: list)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }
    let chatGPT = "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"
    // The app only reads: `snapshotURL` (http(s) or file://) is produced by a collector elsewhere. See README.
    var snapshotURL: URL? { UserDefaults.standard.string(forKey: "snapshotURL").flatMap { URL(string: $0) } }
    var cacheURL: URL { runtime.appendingPathComponent("remote-snapshot.json") }
    var snapshotFile: URL {
        if preview, let path = ProcessInfo.processInfo.environment["LLM_PREVIEW_SNAPSHOT"] { return URL(fileURLWithPath: path) }
        return cacheURL
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = ""
        item.button?.imagePosition = .imageOnly
        item.button?.target = self
        item.button?.action = #selector(statusClicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        if !accounts.isEmpty { MenuUsageRing.accounts = accounts.map { ($0.id, $0.menuLabel ?? $0.label ?? String($0.name.prefix(1)), $0.displayName) } }
        updateMenuRings(rows: [])
        let menu = NSMenu()
        for (title, action) in [("Show Widget", #selector(showWidget)), ("Refresh Now", #selector(refresh)), ("Move to Top Right", #selector(resetPosition)), ("Light Appearance", #selector(light)), ("Dark Appearance", #selector(dark)), ("Use System Appearance", #selector(system)), ("Quit LLM Usage", #selector(quit))] {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = self
            menu.addItem(entry)
        }
        for (title, key) in [("Desktop layout", "desktopRows"), ("Popover layout", "popoverRows")] {
            let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let choices = NSMenu(title: title)
            for (label, rows) in [("One row", 1), ("Two rows", 2)] {
                let entry = NSMenuItem(title: label, action: #selector(changeLayout(_:)), keyEquivalent: "")
                entry.target = self; entry.tag = rows; entry.representedObject = key
                choices.addItem(entry); layoutItems.append(entry)
            }
            parent.submenu = choices; menu.insertItem(parent, at: menu.numberOfItems - 1)
        }
        let glassItem = NSMenuItem()
        let glassControls = NSView(frame: NSRect(x: 0, y: 0, width: 250, height: 66))
        let label = NSTextField(labelWithString: "Glass intensity")
        label.frame = NSRect(x: 18, y: 41, width: 220, height: 18)
        label.font = NSFont.systemFont(ofSize: 12)
        glassControls.addSubview(label)
        glassLabel = label
        let slider = NSSlider(value: glassIntensity, minValue: 15, maxValue: 100, target: self, action: #selector(changeGlassIntensity(_:)))
        slider.frame = NSRect(x: 18, y: 12, width: 214, height: 22)
        slider.isContinuous = true
        slider.toolTip = "100% is a solid off-white (dark: solid green-black) background; lower values let the desktop show through. Text stays opaque."
        glassControls.addSubview(slider)
        glassSlider = slider
        glassItem.view = glassControls
        menu.insertItem(NSMenuItem.separator(), at: menu.numberOfItems - 1)
        menu.insertItem(glassItem, at: menu.numberOfItems - 1)
        menu.insertItem(NSMenuItem.separator(), at: menu.numberOfItems - 1)
        settingsMenu = menu
        settingsMenu.delegate = self
        panel = DesktopPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 520), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        // Sit above Finder's desktop input surface while remaining below ordinary windows.
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.delegate = self
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 520))
        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "widget")
        web = WKWebView(frame: root.bounds, configuration: config)
        web.autoresizingMask = [.width, .height]
        web.setValue(false, forKey: "drawsBackground")
        web.navigationDelegate = self
        let glass = NSVisualEffectView(frame: root.bounds.insetBy(dx: 8, dy: 8))
        glass.autoresizingMask = [.width, .height]
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.appearance = NSAppearance(named: .darkAqua)
        glass.wantsLayer = true
        glass.layer?.cornerRadius = 25
        glass.layer?.masksToBounds = true
        root.addSubview(glass)
        root.addSubview(web)
        let drag = DragArea(frame: NSRect(x: 24, y: 474, width: 264, height: 28))
        dragArea = drag
        drag.toolTip = "Drag to move"
        root.addSubview(drag)
        panel.contentView = root
        if !panel.setFrameUsingName("LLMUsageWidget") { resetPosition() }
        if !preview { panel.setFrameAutosaveName("LLMUsageWidget") }
        let page = Bundle.main.url(forResource: "widget", withExtension: "html")!
        web.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        configurePopover(page: page)
        applyLayout()
        panel.orderFrontRegardless()
        if preview { return }
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.loadSnapshot(); self?.detectAppProfile() }
        fetchTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.fetchRemote() }
        fetchRemote()
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(appsChanged), name: name, object: nil)
        }
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(appearanceChanged), name: NSNotification.Name("AppleInterfaceThemeChangedNotification"), object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(woke), name: NSWorkspace.didWakeNotification, object: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript("setAccounts(\(accountsJSON))")
        lastData = nil
        loadSnapshot()
        applyTheme()
        applyGlassIntensity()
        applyLayout()
        if let row = switchingRow { callJS("switchStarted", [row]) }
        if refreshProcess?.isRunning == true { webView.evaluateJavaScript("refreshStarted()") }
        webView.evaluateJavaScript("setSource({ok:\(sourceOK)})")
        if !preview { detectAppProfile() }
    }
    func configurePopover(page: URL) {
        let controller = NSViewController()
        controller.view = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 248))
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(self, name: "widget")
        configuration.userContentController.addUserScript(WKUserScript(source: "document.body.classList.add('compact')", injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let compactWeb = WKWebView(frame: controller.view.bounds, configuration: configuration)
        compactWeb.autoresizingMask = [.width, .height]
        compactWeb.setValue(false, forKey: "drawsBackground")
        compactWeb.navigationDelegate = self
        controller.view.addSubview(compactWeb)
        popoverWeb = compactWeb
        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        popover.contentSize = controller.view.bounds.size
        popover.contentViewController = controller
        compactWeb.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
    }
    @objc func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp || NSApp.currentEvent?.modifierFlags.contains(.control) == true {
            showSettings()
        } else { togglePopover() }
    }
    func togglePopover() {
        guard let button = item.button else { return }
        if popover.isShown { popover.performClose(nil); return }
        loadSnapshot()
        fetchRemote()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        button.highlight(true)
        // Without this, WebKit keeps focus on its first button and the native open/close/reopen check flaked (2-4 of 6 runs).
        popover.contentViewController?.view.window?.makeFirstResponder(nil)
    }
    func popoverDidClose(_ notification: Notification) {
        item.button?.highlight(false)
    }
    @objc func showSettings() {
        popover.performClose(nil)
        guard let button = item.button else { return }
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            self.settingsMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button)
        }
    }
    func menuWillOpen(_ menu: NSMenu) {
        guard previewMenu else { return }
        settingsOpenedAt = Date()
        writeSettingsCheck(closed: false)
        if CommandLine.arguments.contains("--preview-settings") {
            let timer = Timer(timeInterval: 1, repeats: false) { _ in menu.cancelTracking() }
            RunLoop.main.add(timer, forMode: .common)
        }
    }
    func menuDidClose(_ menu: NSMenu) {
        if previewMenu { writeSettingsCheck(closed: true) }
    }
    func writeSettingsCheck(closed: Bool) {
        let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LLM_PREVIEW_DIR"] ?? NSTemporaryDirectory())
        let check: [String: Any] = ["opened": settingsOpenedAt != nil, "closed": closed,
            "visibleSeconds": settingsOpenedAt.map { Date().timeIntervalSince($0) } ?? 0,
            "items": settingsMenu.items.map(\.title), "hasGlassSlider": glassSlider != nil]
        if let data = try? JSONSerialization.data(withJSONObject: check, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: folder.appendingPathComponent("settings-check.json"), options: .atomic)
        }
    }
    func updateMenuRings(rows: [[String: Any]]) {
        let rings = MenuUsageRing.make(rows: rows)
        item.button?.image = MenuUsageRing.image(rings)
        let description = rings.map(\.summary).joined(separator: "\n")
        item.button?.toolTip = description + "\nClick for details · Right-click for settings"
        item.button?.setAccessibilityLabel("LLM Usage. " + rings.map(\.summary).joined(separator: ". "))
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? String else { return }
        if body == "refresh" { refresh() }
        else if body == "settings" { showSettings() }
        else if body.hasPrefix("switch:") { switchApp(to: String(body.dropFirst(7))) }
    }
    func callJS(_ function: String, _ arguments: [Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: arguments), let text = String(data: data, encoding: .utf8) else { return }
        web?.evaluateJavaScript("\(function)(...\(text))")
        popoverWeb?.evaluateJavaScript("\(function)(...\(text))")
    }
    // Same effect as codex_app_me/iu/su: the profile script quits ChatGPT and relaunches it on that CODEX_HOME.
    func switchApp(to row: String) {
        guard switchProcess?.isRunning != true, let profile = profiles.first(where: { $0.row == row }) else { return }
        let process = Process()
        process.executableURL = home.appendingPathComponent(".local/bin/codex-app-profile")
        process.arguments = [profile.name]
        let errors = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        process.terminationHandler = { [weak self] finished in
            let detail = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                self?.switchProcess = nil
                self?.switchingRow = nil
                self?.callJS("switchFinished", [row, finished.terminationStatus == 0, detail])
                self?.detectAppProfile()
                // The relaunched app may still be starting; confirm once it has settled.
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self?.detectAppProfile() }
            }
        }
        do { try process.run(); switchProcess = process; switchingRow = row; callJS("switchStarted", [row]) }
        catch { callJS("switchFinished", [row, false, "Switch command unavailable"]) }
    }
    @objc func appsChanged(_ notification: Notification) {
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        if app?.bundleIdentifier == "com.openai.codex" { detectAppProfile() }
    }
    func detectAppProfile() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let state = self.readAppProfile()
            DispatchQueue.main.async { self.callJS("updateAppProfile", [state]) }
        }
    }
    func ps(_ arguments: [String]) -> String {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
    // Reads CODEX_HOME from the running app's environment, preferring its Codex backend; only the path leaves this function.
    func readAppProfile() -> [String: Any] {
        var mains: [String] = [], backends: [String] = []
        let rows = ps(["-axo", "pid=,ppid=,comm="]).split(separator: "\n").map { $0.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true).map(String.init) }
        for parts in rows where parts.count == 3 && parts[2] == chatGPT { mains.append(parts[0]) }
        for parts in rows where parts.count == 3 && mains.contains(parts[1]) && parts[2].hasSuffix("/MacOS/codex") { backends.append(parts[0]) }
        guard !mains.isEmpty else {
            let last = (try? String(contentsOf: home.appendingPathComponent(".local/state/codex-app-profile"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
            return ["running": false, "id": profiles.first(where: { $0.name == last })?.row ?? NSNull()]
        }
        var codexHome = home.appendingPathComponent(".codex").path
        for pid in backends + mains {
            let text = ps(["-E", "-ww", "-o", "command=", "-p", pid])
            if let range = text.range(of: #"(?<=\sCODEX_HOME=)\S+"#, options: .regularExpression) { codexHome = String(text[range]); break }
        }
        let resolved = URL(fileURLWithPath: codexHome).standardizedFileURL.path
        let match = profiles.first(where: { home.appendingPathComponent($0.dir).standardizedFileURL.path == resolved })
        return ["running": true, "id": match?.row ?? NSNull(), "home": (resolved as NSString).abbreviatingWithTildeInPath]
    }
    func loadSnapshot() {
        guard let data = remoteData ?? (try? Data(contentsOf: snapshotFile)), data.count < 128_000,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = json["rows"] as? [[String: Any]] else {
            updateMenuRings(rows: currentRows)
            return
        }
        currentRows = rows
        updateMenuRings(rows: rows)
        guard data != lastData else { return }
        // Credential-scope hashes are internal cache guards, never passed into the widget.
        let safeRows = rows.map { row -> [String: Any] in var safe = row; safe.removeValue(forKey: "scope"); safe.removeValue(forKey: "owner"); return safe }
        var safe: [String: Any] = ["rows": safeRows]
        if let collectedAt = json["collectedAt"] { safe["collectedAt"] = collectedAt }
        guard let encoded = try? JSONSerialization.data(withJSONObject: safe), let text = String(data: encoded, encoding: .utf8) else { return }
        web.evaluateJavaScript("updateSnapshot(\(text))") { [weak self] _, error in
            if error == nil {
                self?.lastData = data
                if self?.captured == false { self?.captured = true; self?.captureRenderCheck() }
            }
        }
        popoverWeb?.evaluateJavaScript("updateSnapshot(\(text))")
    }
    // Ties preview evidence to the binary and run that produced it.
    var evidenceStamp: [String: Any] {
        let path = Bundle.main.executablePath ?? ""
        let modified = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return ["binary": path, "binaryModified": modified, "runId": ProcessInfo.processInfo.environment["LLM_PREVIEW_RUN"] ?? ""]
    }
    // Shared by the desktop and popover preview checks.
    let checkScript = "{geometry:inspectGeometry(),compact:document.body.classList.contains('compact'),layoutRows:getComputedStyle(document.getElementById('accounts')).gridTemplateColumns.split(' ').length===4?1:2,ringColor:getComputedStyle(document.querySelector('.arc.weekly')).stroke,ringToken:getComputedStyle(document.body).getPropertyValue('--ring').trim(),fiveColor:getComputedStyle(document.querySelector('.arc.five-hour')).stroke,fiveToken:getComputedStyle(document.body).getPropertyValue('--five').trim(),badges:document.querySelectorAll('.five-badge').length,badgeGeometry:inspectRingGeometry(),rows:document.querySelectorAll('.account').length,text:document.body.innerText,clipped:document.querySelector('.widget').scrollHeight>document.querySelector('.widget').clientHeight,overflow:[...document.querySelectorAll('.account')].some(e=>e.scrollWidth>e.clientWidth),arcs:document.querySelectorAll('.arc').length,paces:document.querySelectorAll('.pace').length,logos:document.querySelectorAll('.identity svg').length,cards:[...document.querySelectorAll('.account')].map(e=>{const r=e.getBoundingClientRect();return {x:r.x,y:r.y,width:r.width,height:r.height}}),glassTint:getComputedStyle(document.documentElement).getPropertyValue('--glass-tint'),focused:document.activeElement?document.activeElement.tagName+'.'+document.activeElement.className:null,focusOutline:document.activeElement?getComputedStyle(document.activeElement).outlineStyle:'none',settings:getComputedStyle(document.querySelector('.settings')).display!=='none'}"
    func captureRenderCheck() {
        guard preview else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self = self else { return }
            let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LLM_PREVIEW_DIR"] ?? NSTemporaryDirectory())
            self.web.evaluateJavaScript("JSON.stringify(\(self.checkScript))") { value, _ in
                if let text = value as? String, let data = text.data(using: .utf8), var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    json.merge(self.evidenceStamp) { $1 }
                    try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("render-check.json"), options: .atomic)
                }
            }
            self.web.createPDF(configuration: WKPDFConfiguration()) { result in
                if case .success(let data) = result { try? data.write(to: folder.appendingPathComponent("preview.pdf"), options: .atomic) }
                if self.previewMenu { self.capturePopoverCheck() }
                else { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { NSApp.terminate(nil) } }
            }
        }
    }
    func capturePopoverCheck(attempt: Int = 0) {
        guard let compactWeb = popoverWeb, !compactWeb.isLoading else {
            if attempt < 20 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.capturePopoverCheck(attempt: attempt + 1) } }
            return
        }
        let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LLM_PREVIEW_DIR"] ?? NSTemporaryDirectory())
        let iconPreview = NSImageView(frame: NSRect(x: 0, y: 0, width: 96, height: 22))
        iconPreview.image = item.button?.image
        try? iconPreview.dataWithPDF(inside: iconPreview.bounds).write(to: folder.appendingPathComponent("menu-bar-preview.pdf"), options: .atomic)
        item.button?.performClick(nil)
        let opened = popover.isShown
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            self.item.button?.performClick(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                let closed = !self.popover.isShown
                self.item.button?.performClick(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    let reopened = self.popover.isShown
                    compactWeb.evaluateJavaScript("JSON.stringify(\(self.checkScript))") { value, error in
                        var check: [String: Any] = [:]
                        if let text = value as? String, let data = text.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { check = json }
                        check["openedByButton"] = opened
                        check["closedByButton"] = closed
                        check["reopenedByButton"] = reopened
                        check["transient"] = self.popover.behavior == .transient
                        check.merge(self.evidenceStamp) { $1 }
                        check["weeklySummaries"] = MenuUsageRing.make(rows: self.currentRows).map(\.summary)
                        check["menuImageWidth"] = self.item.button?.image?.size.width
                        if let error { check["error"] = error.localizedDescription }
                        if let data = try? JSONSerialization.data(withJSONObject: check, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: folder.appendingPathComponent("menu-check.json"), options: .atomic) }
                    }
                    compactWeb.createPDF(configuration: WKPDFConfiguration()) { result in
                        if case .success(let data) = result { try? data.write(to: folder.appendingPathComponent("menu-preview.pdf"), options: .atomic) }
                        if CommandLine.arguments.contains("--preview-settings") {
                            self.showSettings()
                        }
                    }
                }
            }
        }
        // --preview-menu stays open for visual inspection; the installer stops it.
    }
    @objc func showWidget() { panel.orderFrontRegardless() }
    @objc func resetPosition() {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: frame.maxX - panel.frame.width - 30, y: frame.maxY - panel.frame.height - 30))
        if !preview { panel.saveFrame(usingName: "LLMUsageWidget") }
    }
    // Re-read the snapshot source; on failure keep the last snapshot (the widget marks it stale).
    // A request made while one is in flight runs again afterwards, so callers always see a fetch that started after them.
    func fetchRemote(completion: (() -> Void)? = nil) {
        if let completion { fetchCompletions.append(completion) }
        guard !preview else { finishFetches(); return }
        guard !fetching else { refetch = true; return }
        guard let url = snapshotURL else {
            sourceOK = false
            callJS("setSource", [["ok": false, "unconfigured": true]])
            loadSnapshot()
            finishFetches()
            return
        }
        fetching = true
        refetch = false
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode
            let valid: Data? = {
                // A file:// snapshot (a local collector's output) has no HTTP status.
                guard request.url?.isFileURL == true || status == 200, let data, data.count < 128_000,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      json["schemaVersion"] as? Int == 1, let rows = json["rows"] as? [[String: Any]], !rows.isEmpty else { return nil }
                return data
            }()
            DispatchQueue.main.async {
                guard let self else { return }
                self.fetching = false
                if let valid {
                    self.remoteData = valid
                    // The cache only serves the next launch; display uses the validated response directly.
                    try? FileManager.default.createDirectory(at: self.runtime, withIntermediateDirectories: true)
                    try? valid.write(to: self.cacheURL, options: .atomic)
                }
                self.sourceOK = valid != nil
                self.callJS("setSource", [["ok": self.sourceOK]])
                self.loadSnapshot()
                if self.refetch { self.fetchRemote() } else { self.finishFetches() }
            }
        }.resume()
    }
    func finishFetches() {
        let completions = fetchCompletions
        fetchCompletions = []
        completions.forEach { $0() }
    }
    // Manual refresh: run `refreshCommand` (zsh) if set — typically a collector — then re-read the snapshot.
    @objc func refresh() {
        guard !preview, refreshProcess?.isRunning != true else { return }
        callJS("refreshStarted", [])
        guard let command = UserDefaults.standard.string(forKey: "refreshCommand"), !command.isEmpty else {
            fetchRemote { [weak self] in self?.callJS("refreshFinished", []) }
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] finished in
            let code = finished.terminationStatus
            DispatchQueue.main.async {
                self?.refreshProcess = nil
                self?.fetchRemote {
                    self?.callJS("refreshFinished", [])
                    if code != 0 { self?.callJS("setStatus", ["Refresh command failed (exit \(code))"]) }
                }
            }
        }
        do { try process.run(); refreshProcess = process }
        catch { fetchRemote { [weak self] in self?.callJS("refreshFinished", []); self?.callJS("setStatus", ["Refresh command could not start"]) } }
    }
    func rowCount(_ key: String) -> Int {
        let override = preview ? ProcessInfo.processInfo.environment["LLM_PREVIEW_" + key] : nil
        let saved = override.flatMap(Int.init) ?? (UserDefaults.standard.object(forKey: key) as? Int) ?? (key == "desktopRows" ? 2 : 1)
        return saved == 1 ? 1 : 2
    }
    @objc func changeLayout(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        if !preview { UserDefaults.standard.set(sender.tag, forKey: key) }
        applyLayout()
    }
    func applyLayout() {
        let desktopRows = rowCount("desktopRows"), compactRows = rowCount("popoverRows")
        let size = desktopRows == 1 ? NSSize(width: 660, height: 294) : NSSize(width: 360, height: 508)
        let old = panel.frame
        panel.setContentSize(size)
        var origin = NSPoint(x: old.maxX - size.width, y: old.maxY - size.height)
        if let screen = panel.screen ?? NSScreen.main {
            let frame = screen.visibleFrame
            origin.x = min(max(origin.x, frame.minX), frame.maxX - size.width)
            origin.y = min(max(origin.y, frame.minY), frame.maxY - size.height)
        }
        panel.setFrameOrigin(origin)
        dragArea?.frame = NSRect(x: 24, y: size.height - 46, width: size.width - 112, height: 28)
        let compactSize = compactRows == 1 ? NSSize(width: 440, height: 224) : NSSize(width: 248, height: 388)
        popover?.contentSize = compactSize
        web?.evaluateJavaScript("setLayout(\(desktopRows))")
        popoverWeb?.evaluateJavaScript("setLayout(\(compactRows))")
        for entry in layoutItems {
            entry.state = entry.tag == rowCount(entry.representedObject as? String ?? "desktopRows") ? .on : .off
        }
    }
    var glassIntensity: Double {
        let saved = UserDefaults.standard.object(forKey: "glassIntensity") as? Double ?? 50
        return min(100, max(15, saved))
    }
    @objc func changeGlassIntensity(_ sender: NSSlider) {
        UserDefaults.standard.set(sender.doubleValue, forKey: "glassIntensity")
        applyGlassIntensity()
    }
    func applyGlassIntensity() {
        let value = glassIntensity
        // Only the backdrop changes opacity; the WebKit labels/rings stay crisp.
        (panel?.contentView?.subviews.first as? NSVisualEffectView)?.alphaValue = value / 100
        glassSlider?.doubleValue = value
        glassLabel?.stringValue = "Glass intensity: \(Int(value.rounded()))%"
        callJS("setGlassIntensity", [value])
    }
    @objc func light() { UserDefaults.standard.set("light", forKey: "appearance"); applyTheme() }
    @objc func dark() { UserDefaults.standard.set("dark", forKey: "appearance"); applyTheme() }
    @objc func system() { UserDefaults.standard.set("system", forKey: "appearance"); applyTheme() }
    @objc func appearanceChanged() { applyTheme() }
    func applyTheme() {
        let mode = UserDefaults.standard.string(forKey: "appearance")
        let isDark = mode == "dark" || (mode == "system" && NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        (panel?.contentView?.subviews.first as? NSVisualEffectView)?.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        popover?.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        callJS("setTheme", [isDark])
    }
    @objc func woke() {
        showWidget()
        // Give the network a moment to return after sleep.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.fetchRemote() }
    }
    @objc func quit() { NSApp.terminate(nil) }
    func windowDidMove(_ notification: Notification) { if !preview { panel.saveFrame(usingName: "LLMUsageWidget") } }
}

@main enum LLMUsageMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
