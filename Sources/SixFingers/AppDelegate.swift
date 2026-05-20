import AppKit

struct PromptResult {
    enum Kind { case text, file }
    let type: Kind
    let value: String
}

/// What we composite onto the hand glyph for a given state. The hand is always the
/// base; an overlay is knocked out of it so the menu bar background shows through.
enum TrayOverlay: Equatable {
    case digit(Int)
    case symbol(String)
}

/// Single source of truth for everything the user sees in the menu bar: icon tint,
/// overlay glyph, pulse animation, and the disabled status banner at the top of the
/// dropdown menu. Replaces the old `setStatus(String)` text path so the menu bar
/// footprint stays a fixed 22×22 icon at all times.
enum TrayState: Equatable {
    case idle
    case picking
    case waitingPermission(seconds: Int?)
    case listening
    case transcribing
    case thinking
    case drawing(progress: Int?)
    case countdown(Int)
    case done
    case failed
    case cancelled

    /// Human-readable status shown as the (disabled, grayed) first menu item.
    /// `nil` hides the row entirely — that is how we mark "no status to surface".
    var menuDescription: String? {
        switch self {
        case .idle: return nil
        case .picking: return "Drag to select drawing area"
        case .waitingPermission(let seconds):
            if let seconds, seconds > 0 { return "Waiting for Accessibility (\(seconds)s)" }
            return "Waiting for Accessibility…"
        case .listening: return "Listening…"
        case .transcribing: return "Transcribing…"
        case .thinking: return "Thinking…"
        case .drawing(let progress):
            if let progress { return "Drawing \(progress)%" }
            return "Drawing…"
        case .countdown(let n): return "Drawing in \(n)s"
        case .done: return "Done"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }

    /// States that need the pulsing-alpha animator running.
    var needsPulse: Bool {
        switch self {
        case .listening, .transcribing: return true
        default: return false
        }
    }

    /// Explicit color for states that must survive the menu bar's auto-tinting.
    /// Yellow = "warming up, not drawing yet" (thinking, countdown, permission wait).
    /// Green = "actively drawing or just finished". Red = failure. Nil = template.
    var iconTint: NSColor? {
        switch self {
        case .thinking, .countdown, .waitingPermission: return .systemYellow
        case .drawing, .done: return .systemGreen
        case .failed: return .systemRed
        default: return nil
        }
    }

    /// Glyph composited over the hand, knocked out with `.destinationOut`.
    var iconOverlay: TrayOverlay? {
        switch self {
        case .countdown(let n): return .digit(n)
        case .waitingPermission(let seconds):
            if let seconds, seconds > 0 { return .digit(seconds) }
            return nil
        case .done: return .symbol("checkmark")
        case .failed, .cancelled: return .symbol("xmark")
        default: return nil
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
    var statusItem: NSStatusItem!
    /// Re-entry guard for the draw flow. All visible feedback lives on `state`; this
    /// boolean only gates whether a new draw can begin.
    var drawing = false

    /// Current tray presentation. Always mutate via `setTrayState` / `flashTrayState`
    /// so the icon, menu header, and pulse animator stay in sync.
    private(set) var state: TrayState = .idle

    let settingsController = SettingsWindowController()
    var pickerController: AreaPickerController?  // retain picker

    var appIcon: NSImage?

    /// The unmodified hand glyph for the menu bar status item; we keep it so we can
    /// rebuild overlay variants (countdown numbers, etc.) and restore the bare icon.
    private var baseTrayIcon: NSImage?

    /// The disabled "status banner" at the top of the dropdown menu and its trailing
    /// separator. Both hide together when `state == .idle`.
    private weak var statusHeaderItem: NSMenuItem?
    private weak var statusHeaderSeparator: NSMenuItem?

    /// Drives the pulsing-alpha animation for transient states (listening, transcribing).
    private var pulseTimer: Timer?
    private var pulseAlpha: CGFloat = 1.0
    private var pulseDirection: CGFloat = -1

    /// Polls `AXIsProcessTrusted` after we send the user to Accessibility settings; never runs unbounded.
    private var accessibilityTrustTimer: Timer?
    private var accessibilityWaitStarted: Date?
    private var lastAccessibilityStatusSecond: Int = -1

    private enum AccessibilityPolling {
        static let interval: TimeInterval = 1
        static let maxWaitSeconds: TimeInterval = 30
        static let statusEverySeconds = 10
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        let exe = accessibilityExecutablePathForHelp()
        fputs(
            "SixFingers (debug): running as menu bar app — terminal stays open until we quit.\n  Accessibility must match this path if using swift run:\n  \(exe)\n",
            stderr
        )
        #endif

        // Load rounded icon for alerts (square icon used for Finder/Dock via icns)
        for p in [Bundle.main.resourcePath.map { "\($0)/icon-rounded.png" },
                   Bundle.main.resourcePath.map { "\($0)/Resources/icon-rounded.png" }].compactMap({ $0 }) {
            if let img = NSImage(contentsOfFile: p) { appIcon = img; break }
        }

        registerBundledFonts()

        // Set as app icon so all NSAlerts use the rounded version
        if let icon = appIcon { NSApp.applicationIconImage = icon }

        // Enable standard Edit menu for Cmd+C/V/X/A in text fields
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem()
        editItem.submenu = editMenu
        NSApp.mainMenu = NSMenu()
        NSApp.mainMenu?.addItem(editItem)

        // Hide dock icon
        NSApp.setActivationPolicy(.accessory)

        // Create status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            // Try multiple paths for the tray icon
            let candidates = [
                Bundle.main.resourcePath.map { "\($0)/Resources/tray-iconTemplate@2x.png" },
                Bundle.main.resourcePath.map { "\($0)/tray-iconTemplate@2x.png" },
                // Dev mode: relative to executable
                URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
                    .deletingLastPathComponent().appendingPathComponent("../../Resources/tray-iconTemplate@2x.png").path,
                // Electron version's icon
                
            ].compactMap { $0 }

            var loaded = false
            for path in candidates {
                if let img = NSImage(contentsOfFile: path) {
                    img.isTemplate = true
                    img.size = NSSize(width: 22, height: 22)
                    button.image = img
                    baseTrayIcon = img
                    loaded = true
                    break
                }
            }
            if !loaded {
                let fallback = NSImage(systemSymbolName: "hand.draw", accessibilityDescription: "SixFingers")
                fallback?.isTemplate = true
                button.image = fallback
                baseTrayIcon = fallback
            }
        }

        buildMenu()

        // First launch: check permissions then open Draw
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            if !checkAccessibilityForDrawing() {
                // Show permission request dialog that waits
                self.showPermissionDialog()
            } else if SettingsManager.shared.getApiKey() == nil {
                self.onDraw()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        accessibilityTrustTimer?.invalidate()
        accessibilityTrustTimer = nil
    }

    /// Registers the bundled Silkscreen TTFs with CoreText so we can address them by
    /// PostScript name (e.g. `Silkscreen`). Process-scoped, no install prompt, idempotent —
    /// re-registration after the first call is a no-op the OS handles cleanly.
    private func registerBundledFonts() {
        let names = ["Silkscreen-Regular", "Silkscreen-Bold"]
        let resourcePath = Bundle.main.resourcePath
        for name in names {
            let candidates = [
                resourcePath.map { "\($0)/fonts/\(name).ttf" },
                resourcePath.map { "\($0)/Resources/fonts/\(name).ttf" },
                URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
                    .deletingLastPathComponent()
                    .appendingPathComponent("../../Resources/fonts/\(name).ttf").path,
            ].compactMap { $0 }
            for path in candidates where FileManager.default.fileExists(atPath: path) {
                CTFontManagerRegisterFontsForURL(URL(fileURLWithPath: path) as CFURL, .process, nil)
                break
            }
        }
    }

    /// Primary mutator for tray presentation. Marshals to the main thread and refreshes
    /// the icon, the dropdown's status header, and the pulse animator together so they
    /// can never drift out of sync.
    func setTrayState(_ next: TrayState) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { self.setTrayState(next) }
            return
        }
        guard state != next else { return }
        state = next
        refreshTrayPresentation()
    }

    /// Sets a transient state (done / failed / cancelled) for `duration` seconds, then
    /// returns to `.idle` — but only if nothing else has taken over in the meantime.
    func flashTrayState(_ flash: TrayState, duration: TimeInterval = 2.0) {
        setTrayState(flash)
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self else { return }
            if self.state == flash { self.setTrayState(.idle) }
        }
    }

    private func refreshTrayPresentation() {
        guard let button = self.statusItem?.button else { return }
        button.title = ""
        button.image = self.renderTrayIcon(for: state)
        let desc = state.menuDescription
        statusHeaderItem?.title = desc ?? ""
        statusHeaderItem?.isHidden = (desc == nil)
        statusHeaderSeparator?.isHidden = (desc == nil)
        applyPulseForState()
    }

    private func applyPulseForState() {
        if state.needsPulse {
            startPulseIfNeeded()
        } else {
            stopPulse()
        }
    }

    private func startPulseIfNeeded() {
        guard pulseTimer == nil else { return }
        pulseAlpha = 1.0
        pulseDirection = -1
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self, let button = self.statusItem?.button else { return }
            self.pulseAlpha += self.pulseDirection * 0.04
            if self.pulseAlpha <= 0.35 { self.pulseAlpha = 0.35; self.pulseDirection = 1 }
            else if self.pulseAlpha >= 1.0 { self.pulseAlpha = 1.0; self.pulseDirection = -1 }
            button.alphaValue = self.pulseAlpha
        }
        pulseTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopPulse() {
        pulseTimer?.invalidate()
        pulseTimer = nil
        statusItem?.button?.alphaValue = 1.0
    }

    /// Returns the seconds count from countdown messages the draw engine emits
    /// (e.g. "Drawing in 3s", "Resuming in 1s"). "Drawing 50%" does not match.
    private func countdownSeconds(in text: String) -> Int? {
        let pattern = #"^(?:Drawing|Resuming) in (\d+)s$"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let match = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return Int(text[range])
    }

    /// Returns the percentage from progress messages (e.g. "Drawing 50%").
    private func drawProgressPercent(in text: String) -> Int? {
        guard let match = text.range(of: #"Drawing (\d+)%"#, options: .regularExpression) else { return nil }
        return Int(text[match].filter { $0.isNumber })
    }

    /// Composites the hand glyph for `state`: optional color tint + optional knockout overlay
    /// (digit or SF Symbol). The template flag is flipped off whenever we apply an explicit
    /// tint so the color survives the menu bar's auto-tinting.
    private func renderTrayIcon(for state: TrayState) -> NSImage? {
        guard let base = baseTrayIcon else { return nil }
        let size = NSSize(width: 22, height: 22)
        let tint = state.iconTint
        let overlay = state.iconOverlay
        let image = NSImage(size: size, flipped: false) { rect in
            if let tint {
                tint.setFill()
                rect.fill()
                base.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1.0)
            } else {
                base.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
            }
            if let overlay {
                self.drawOverlayKnockout(overlay, in: rect)
            }
            return true
        }
        image.isTemplate = (tint == nil)
        return image
    }

    private func drawOverlayKnockout(_ overlay: TrayOverlay, in rect: NSRect) {
        switch overlay {
        case .digit(let value):
            let text = "\(value)" as NSString
            // Silkscreen is a pixel/bitmap font — bundled via registerBundledFonts(). The
            // system-font fallback only fires if registration failed for some reason.
            let font = NSFont(name: "Silkscreen", size: 14)
                ?? NSFont.systemFont(ofSize: 13, weight: .heavy)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.black,
            ]
            let textSize = text.size(withAttributes: attrs)
            let textRect = NSRect(
                x: (rect.width - textSize.width) / 2,
                y: (rect.height - textSize.height) / 2,
                width: textSize.width,
                height: textSize.height
            )
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            text.draw(in: textRect, withAttributes: attrs)
            NSGraphicsContext.current?.compositingOperation = .sourceOver
        case .symbol(let name):
            guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return }
            let inset = rect.insetBy(dx: 5, dy: 5)
            symbol.draw(in: inset, from: .zero, operation: .destinationOut, fraction: 1.0)
        }
    }

    func buildMenu() {
        let menu = NSMenu()
        let settings = SettingsManager.shared.load()

        // Disabled "status banner" — the only place text describes what the icon means.
        // Stays hidden while we are idle; reappears whenever `state` carries a description.
        // No action means NSMenu's auto-validation leaves it grayed without us setting state.
        let header = NSMenuItem(title: state.menuDescription ?? "", action: nil, keyEquivalent: "")
        header.isHidden = (state.menuDescription == nil)
        menu.addItem(header)
        let headerSeparator = NSMenuItem.separator()
        headerSeparator.isHidden = (state.menuDescription == nil)
        menu.addItem(headerSeparator)
        statusHeaderItem = header
        statusHeaderSeparator = headerSeparator

        // Draw
        let drawItem = NSMenuItem(title: "Draw...", action: #selector(onDraw), keyEquivalent: "")
        drawItem.target = self
        menu.addItem(drawItem)

        menu.addItem(.separator())

        // Recent
        let recents = SettingsManager.shared.loadRecents()
        if !recents.isEmpty {
            let recentMenu = NSMenu()
            for entry in recents {
                let label = String(entry.prompt.prefix(40)) + (entry.prompt.count > 40 ? "..." : "")
                let item = NSMenuItem(title: label, action: #selector(onRecent(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = entry
                recentMenu.addItem(item)
            }
            recentMenu.addItem(.separator())
            let clearItem = NSMenuItem(title: "Clear", action: #selector(onClearRecents), keyEquivalent: "")
            clearItem.target = self
            recentMenu.addItem(clearItem)

            let recentItem = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
            recentItem.submenu = recentMenu
            menu.addItem(recentItem)
        }

        // Narrator
        let narratorItem = NSMenuItem(title: "Narrator", action: #selector(onToggleNarrator(_:)), keyEquivalent: "")
        narratorItem.target = self
        narratorItem.state = settings.narratorEnabled ? .on : .off
        menu.addItem(narratorItem)

        menu.addItem(.separator())

        // Settings
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(onSettings), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)

        // About
        let aboutItem = NSMenuItem(title: "About", action: #selector(onAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(onQuit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    // MARK: - Actions

    var drawWindow: NSWindow?
    var drawInput: NSTextField?
    var drawAroundCheck: NSButton?

    @objc func onDraw() {
        guard !drawing else { return }

        if !checkAccessibilityForDrawing() {
            presentAccessibilityRequiredAlert()
            return
        }

        // If no API key, offer settings or random draw
        if SettingsManager.shared.getApiKey() == nil {
            let noKey = NSAlert()
            noKey.messageText = "Let me draw something for you"
            noKey.informativeText = "Open any drawing app and select a brush — I'll take it from there.\n\nWant me to draw anything you can imagine? Set up an AI provider in Settings."
            noKey.addButton(withTitle: "Draw something now")
            noKey.addButton(withTitle: "Open Settings")
            noKey.addButton(withTitle: "Cancel")
            if let icon = appIcon { noKey.icon = icon }
            noKey.window.level = .floating
            NSApp.activate(ignoringOtherApps: true)

            let r = noKey.runModal()
            if r == .alertFirstButtonReturn {
                drawRandomImage()
            } else if r == .alertSecondButtonReturn {
                settingsController.show { [weak self] in self?.buildMenu() }
            }
            return
        }

        showDrawWindow(prefill: nil)
    }

    func showDrawWindow(prefill: String?) {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 220),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "SixFingers"
        w.level = .floating
        w.center()
        self.drawWindow = w

        let cv = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 220))

        // Title
        let title = NSTextField(labelWithString: "What should I draw for you?")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.frame = NSRect(x: 24, y: 172, width: 312, height: 20)
        cv.addSubview(title)

        // Text field
        let input = NSTextField(frame: NSRect(x: 24, y: 140, width: 312, height: 24))
        input.placeholderString = "A penguin riding a bicycle..."
        input.font = .systemFont(ofSize: 13)
        if let t = prefill { input.stringValue = t }
        input.target = self
        input.action = #selector(onDrawSubmit)
        cv.addSubview(input)
        self.drawInput = input

        // Buttons row — mic only shown if API key exists
        let hasKey = SettingsManager.shared.getApiKey() != nil
        let fileBtn = NSButton(title: "📁  Select Image", target: self, action: #selector(onFileFromDraw))
        fileBtn.bezelStyle = .roundRect

        if hasKey {
            let btnW = 152
            let micBtn = NSButton(title: "🎤  Use Mic", target: self, action: #selector(onMicFromDraw))
            micBtn.bezelStyle = .roundRect
            micBtn.frame = NSRect(x: 24, y: 106, width: btnW, height: 28)
            cv.addSubview(micBtn)
            fileBtn.frame = NSRect(x: 24 + btnW + 8, y: 106, width: btnW, height: 28)
        } else {
            fileBtn.frame = NSRect(x: 24, y: 106, width: 312, height: 28)
        }
        cv.addSubview(fileBtn)

        // // Checkbox — only show if AI provider is set
        // let check = NSButton(checkboxWithTitle: "Draw around existing content", target: nil, action: nil)
        // check.frame = NSRect(x: 24, y: 72, width: 312, height: 20)
        // check.state = .off
        // if hasKey {
        //     cv.addSubview(check)
        // }
        // self.drawAroundCheck = check

        // Divider
        let div = NSBox(frame: NSRect(x: 24, y: 80, width: 312, height: 1))
        div.boxType = .separator
        cv.addSubview(div)

        // Bottom buttons — right-aligned
        let cancelBtn = NSButton(title: "Cancel", target: self, action: #selector(onDrawCancel))
        cancelBtn.bezelStyle = .rounded
        cancelBtn.frame = NSRect(x: 172, y: 20, width: 84, height: 30)
        cancelBtn.keyEquivalent = "\u{1b}" // Escape
        cv.addSubview(cancelBtn)

        let drawBtn = NSButton(title: "Draw", target: self, action: #selector(onDrawSubmit))
        drawBtn.bezelStyle = .rounded
        drawBtn.keyEquivalent = "\r" // Enter
        drawBtn.frame = NSRect(x: 264, y: 20, width: 72, height: 30)
        cv.addSubview(drawBtn)

        w.contentView = cv
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(input)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func onDrawSubmit() {
        guard let text = drawInput?.stringValue.trimmingCharacters(in: .whitespaces),
              !text.isEmpty else { return }
        let drawAround = drawAroundCheck?.state == .on
        drawWindow?.orderOut(nil)
        drawWindow = nil

        if drawAround {
            runInpaintFromPrompt(prompt: text)
        } else {
            runDrawFlow(result: PromptResult(type: .text, value: text))
        }
    }

    @objc func onDrawCancel() {
        drawWindow?.orderOut(nil)
        drawWindow = nil
    }

    func drawRandomImage() {
        guard !drawing else { return }

        // Find bundled free drawings
        let searchPaths = [
            Bundle.main.resourcePath.map { "\($0)/Resources/free_drawings" },
            Bundle.main.resourcePath.map { "\($0)/free_drawings" },
            // Dev mode
            URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
                .deletingLastPathComponent()
                .appendingPathComponent("../../Resources/free_drawings").path,
            
        ].compactMap { $0 }

        var images: [String] = []
        for dir in searchPaths {
            if let files = try? FileManager.default.contentsOfDirectory(atPath: dir) {
                images = files.filter { $0.hasSuffix(".png") }.map { "\(dir)/\($0)" }
                if !images.isEmpty { break }
            }
        }

        guard !images.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "No sample drawings found"
            alert.informativeText = "Set up an API key in Settings to generate custom drawings."
            alert.runModal()
            return
        }

        let chosen = images.randomElement()!
        let name = URL(fileURLWithPath: chosen).deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: " ")

        setTrayState(.picking)
        showPicker { [weak self] area in
            guard let self, let area else { self?.setTrayState(.idle); return }
            self.drawing = true
            DispatchQueue.global().async { [weak self] in
                self?.drawImage(imagePath: chosen, prompt: name, area: area)
            }
        }
    }

    func runInpaintFromPrompt(prompt: String) {
        setTrayState(.picking)
        showPicker { [weak self] area in
            guard let self, let area else { self?.setTrayState(.idle); return }
            self.runInpaintFlow(prompt: prompt, area: area)
        }
    }

    @objc func onRecent(_ sender: NSMenuItem) {
        guard !drawing, let entry = sender.representedObject as? RecentEntry else { return }
        if !checkAccessibilityForDrawing() {
            presentAccessibilityRequiredAlert()
            return
        }
        setTrayState(.picking)
        showPicker { [weak self] area in
            guard let self, let area else { self?.setTrayState(.idle); return }
            self.drawing = true
            DispatchQueue.global().async { [weak self] in
                self?.drawImage(imagePath: entry.image, prompt: entry.prompt, area: area)
            }
        }
    }

    @objc func onClearRecents() {
        SettingsManager.shared.clearRecents()
        buildMenu()
    }

    @objc func onStyle(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        var s = SettingsManager.shared.load()
        s.style = name
        SettingsManager.shared.save(s)
        buildMenu()
    }

    @objc func onAddStyle() {
        let alert = NSAlert()
        alert.messageText = "Style Name"
        alert.addButton(withTitle: "Next")
        alert.addButton(withTitle: "Cancel")
        let nameField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        nameField.placeholderString = "e.g. Watercolor"
        alert.accessoryView = nameField
        alert.window.level = .floating
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = nameField.stringValue
        guard !name.isEmpty else { return }

        let alert2 = NSAlert()
        alert2.messageText = "\"\(name)\" Style Prompt"
        alert2.addButton(withTitle: "Save")
        alert2.addButton(withTitle: "Cancel")
        let promptField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        promptField.placeholderString = "Describe the art style..."
        alert2.accessoryView = promptField
        alert2.window.level = .floating
        guard alert2.runModal() == .alertFirstButtonReturn else { return }
        let prompt = promptField.stringValue
        guard !prompt.isEmpty else { return }

        var s = SettingsManager.shared.load()
        s.customStyles[name] = prompt
        s.style = name
        SettingsManager.shared.save(s)
        buildMenu()
    }

    @objc func onToggleNarrator(_ sender: NSMenuItem) {
        var s = SettingsManager.shared.load()
        s.narratorEnabled = !s.narratorEnabled
        SettingsManager.shared.save(s)
        sender.state = s.narratorEnabled ? .on : .off
    }

    @objc func onSettings() {
        settingsController.show { [weak self] in self?.buildMenu() }
    }

    @objc func onAbout() {
        let alert = NSAlert()
        alert.messageText = "SixFingers"
        alert.informativeText = "Drawing on its own.\n\nMade by Dot Fun Labs\nVersion 1.0.0\n\nFeedback: x.com/taydotfun"
        alert.alertStyle = .informational
        if let icon = appIcon { alert.icon = icon }
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Give Feedback")

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertSecondButtonReturn {
            NSWorkspace.shared.open(URL(string: "https://x.com/taydotfun")!)
        }
    }

    @objc func onQuit() {
        NSApp.terminate(nil)
    }

    /// Menu-bar-only apps ignore `activate` while `.accessory`; we briefly use `.regular` so alerts appear above Settings.
    private func presentAttentionAlertThenRestoreAccessory(messageText: String, informativeText: String, completion: @escaping () -> Void) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        defer { NSApp.setActivationPolicy(.accessory) }
        let alert = NSAlert()
        alert.messageText = messageText
        alert.informativeText = informativeText
        alert.addButton(withTitle: "OK")
        if let icon = appIcon { alert.icon = icon }
        alert.alertStyle = .informational
        alert.window.level = .floating
        alert.runModal()
        completion()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Brief dock blip so the click registers — we are still a menu bar app and
        // route back to .accessory after a moment. The "pen icon in menu bar" status
        // text that used to live here moved into the dropdown's status header.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            NSApp.setActivationPolicy(.accessory)
        }
        return true
    }

    /// Shows a blocking alert when drawing needs Accessibility but the app is not trusted yet.
    private func presentAccessibilityRequiredAlert() {
        let present = { [weak self] in
            guard let self else { return }
            let alert = NSAlert()
            alert.messageText = "Accessibility permission required"
            alert.informativeText =
                "SixFingers cannot move the mouse or draw until this exact program is allowed under Privacy & Security → Accessibility:\n\n\(accessibilityExecutablePathForHelp())\n\nIf SixFingers already appears enabled, macOS may have toggled a different build (the installed app vs a Terminal debug binary). Enable the row that matches this path."
            alert.addButton(withTitle: "Open Accessibility Settings")
            alert.addButton(withTitle: "OK")
            if let icon = self.appIcon { alert.icon = icon }
            alert.window.level = .floating
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            }
        }
        if Thread.isMainThread {
            present()
        } else {
            DispatchQueue.main.async { present() }
        }
    }

    func showPermissionDialog() {
        let alert = NSAlert()
        alert.messageText = "SixFingers needs accessibility access"
        alert.informativeText =
            "This lets SixFingers control your mouse to draw.\n\nmacOS enables Accessibility per executable path and code identity. Enable the list row that matches this path:\n\n\(accessibilityExecutablePathForHelp())\n\nIf SixFingers exists in /Applications and also under dist (or elsewhere), Settings can show ON for one path while this run still uses another; expand the list or remove duplicate rows and add only this binary path.\n\nUnsigned or ad-hoc rebuilds change the signature: if it stays stuck, remove SixFingers with −, quit us, reopen from this same path, then enable again; or run: tccutil reset Accessibility com.dotfunlabs.sixfingers\n\nAfter you enable the matching row, we detect it about once per second."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Quit")
        if let icon = appIcon { alert.icon = icon }
        alert.window.level = .floating
        NSApp.activate(ignoringOtherApps: true)

        let response = alert.runModal()
        if response == .alertSecondButtonReturn {
            NSApp.terminate(nil)
            return
        }

        promptSystemAccessibilityRegistration()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)

        startAccessibilityTrustPolling()
    }

    private func startAccessibilityTrustPolling() {
        accessibilityTrustTimer?.invalidate()
        accessibilityWaitStarted = Date()
        lastAccessibilityStatusSecond = -1
        setTrayState(.waitingPermission(seconds: nil))

        let timer = Timer(timeInterval: AccessibilityPolling.interval, repeats: true) { [weak self] t in
            guard let self else {
                t.invalidate()
                return
            }
            let start = self.accessibilityWaitStarted ?? Date()
            let elapsed = Date().timeIntervalSince(start)

            if AXIsProcessTrusted() {
                t.invalidate()
                self.accessibilityTrustTimer = nil
                self.handleAccessibilityTrustGranted()
                return
            }

            if elapsed >= AccessibilityPolling.maxWaitSeconds {
                t.invalidate()
                self.accessibilityTrustTimer = nil
                self.handleAccessibilityTrustWaitTimedOut()
                return
            }

            let sec = Int(elapsed)
            if sec > 0, sec % AccessibilityPolling.statusEverySeconds == 0, sec != self.lastAccessibilityStatusSecond {
                self.lastAccessibilityStatusSecond = sec
                self.setTrayState(.waitingPermission(seconds: sec))
            }
        }
        accessibilityTrustTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func handleAccessibilityTrustGranted() {
        setTrayState(.idle)
        presentAttentionAlertThenRestoreAccessory(
            messageText: "Accessibility enabled",
            informativeText: "SixFingers stays in the menu bar at the top of the screen (near the clock). Look for the pen icon.\n\nRunning open SixFingers.app again focuses us here if the icon is hard to spot."
        ) { [weak self] in
            guard let self else { return }
            if SettingsManager.shared.getApiKey() == nil {
                self.onDraw()
            }
        }
    }

    private func handleAccessibilityTrustWaitTimedOut() {
        setTrayState(.idle)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        defer { NSApp.setActivationPolicy(.accessory) }

        let alert = NSAlert()
        alert.messageText = "Still waiting for Accessibility"
        alert.informativeText =
            "macOS has not granted trust to this build after \(Int(AccessibilityPolling.maxWaitSeconds)) seconds.\n\n\(accessibilityExecutablePathForHelp())\n\nCommon cause: Accessibility is ON for /Applications/SixFingers.app but we are running from dist (or the opposite). Those are separate paths; turn ON the row that matches the path above, or remove both SixFingers entries and add only this app.\n\nAd-hoc rebuilds also change the signature: remove SixFingers with −, quit us, reopen from this path, enable again; or run: tccutil reset Accessibility com.dotfunlabs.sixfingers\n\nYou can keep waiting if permissions are still updating.\n\nWe use no Dock icon; after any alert closes, look for the pen icon in the menu bar."
        alert.addButton(withTitle: "Continue waiting")
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Dismiss")
        if let icon = appIcon { alert.icon = icon }
        alert.alertStyle = .informational
        alert.window.level = .floating

        let r = alert.runModal()
        switch r {
        case .alertFirstButtonReturn:
            startAccessibilityTrustPolling()
        case .alertSecondButtonReturn:
            promptSystemAccessibilityRegistration()
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            startAccessibilityTrustPolling()
        default:
            break
        }
    }

    func showPicker(completion: @escaping (PickerResult?) -> Void) {
        DispatchQueue.main.async { [weak self] in
            let picker = AreaPickerController()
            self?.pickerController = picker
            picker.show { [weak self] result in
                self?.pickerController = nil
                completion(result)
            }
        }
    }

    @objc func onMicFromDraw() {
        drawWindow?.orderOut(nil)
        drawWindow = nil
        setTrayState(.listening)
        let audioPath = recordAudio(duration: 6)
        if let audioPath = audioPath {
            setTrayState(.transcribing)
            Task {
                do {
                    let transcript = try await transcribeAudio(audioPath: audioPath)
                    try? FileManager.default.removeItem(atPath: audioPath)
                    DispatchQueue.main.async { [weak self] in
                        self?.setTrayState(.idle)
                        if !transcript.isEmpty { self?.showDrawWithText(transcript) }
                    }
                } catch {
                    try? FileManager.default.removeItem(atPath: audioPath)
                    DispatchQueue.main.async { [weak self] in
                        self?.flashTrayState(.failed, duration: 2)
                    }
                }
            }
        } else {
            setTrayState(.idle)
        }
    }

    @objc func onFileFromDraw() {
        drawWindow?.orderOut(nil)
        drawWindow = nil
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .image]
        panel.canChooseFiles = true
        panel.level = .floating
        if panel.runModal() == .OK, let url = panel.url {
            runDrawFlow(result: PromptResult(type: .file, value: url.path))
        }
    }

    func recordAudio(duration: Int) -> String? {
        let tmp = NSTemporaryDirectory() + "sf_voice_\(Int(Date().timeIntervalSince1970)).wav"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        proc.arguments = ["-f", "avfoundation", "-i", ":default", "-t", "\(duration)", "-ar", "16000", "-ac", "1", tmp, "-y"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            // Try /usr/local/bin/ffmpeg
            let proc2 = Process()
            proc2.executableURL = URL(fileURLWithPath: "/usr/local/bin/ffmpeg")
            proc2.arguments = proc.arguments
            proc2.standardOutput = FileHandle.nullDevice
            proc2.standardError = FileHandle.nullDevice
            do { try proc2.run(); proc2.waitUntilExit() } catch { return nil }
        }
        return FileManager.default.fileExists(atPath: tmp) ? tmp : nil
    }

    func transcribeAudio(audioPath: String) async throws -> String {
        let s = SettingsManager.shared.load()
        guard let key = SettingsManager.shared.getApiKey() else { throw NSError(domain: "", code: 1) }

        if s.provider == "fal.ai" {
            // Upload to fal storage then transcribe
            let audioData = try Data(contentsOf: URL(fileURLWithPath: audioPath))
            var uploadReq = URLRequest(url: URL(string: "https://fal.run/fal-ai/wizper")!)
            uploadReq.httpMethod = "POST"
            uploadReq.setValue("Key \(key)", forHTTPHeaderField: "Authorization")
            uploadReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let b64 = audioData.base64EncodedString()
            let body: [String: Any] = ["audio_url": "data:audio/wav;base64,\(b64)"]
            uploadReq.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, _) = try await URLSession.shared.data(for: uploadReq)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            return (json?["text"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        }

        if s.provider == "openai" {
            let audioData = try Data(contentsOf: URL(fileURLWithPath: audioPath))
            let boundary = UUID().uuidString
            var req = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
            req.httpMethod = "POST"
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

            var body = Data()
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\nwhisper-1\r\n".data(using: .utf8)!)
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
            body.append(audioData)
            body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
            req.httpBody = body

            let (data, _) = try await URLSession.shared.data(for: req)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            return (json?["text"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        }

        throw NSError(domain: "", code: 2, userInfo: [NSLocalizedDescriptionKey: "Transcription not supported for this provider"])
    }

    func showDrawWithText(_ text: String) {
        guard !drawing else { return }
        showDrawWindow(prefill: text)
    }

    // MARK: - Draw flows

    func runDrawFlow(result: PromptResult) {
        if result.type == .file {
            setTrayState(.picking)
            showPicker { [weak self] area in
                guard let self, let area else { self?.setTrayState(.idle); return }
                self.drawing = true
                DispatchQueue.global().async { [weak self] in
                    self?.drawImage(imagePath: result.value, prompt: "your image", area: area)
                }
            }
            return
        }

        let prompt = result.value
        setTrayState(.picking)
        showPicker { [weak self] area in
            guard let self, let area else { self?.setTrayState(.idle); return }
            let w = abs(area.bottomRight.0 - area.topLeft.0)
            let h = abs(area.bottomRight.1 - area.topLeft.1)
            let aspect = Double(w) / Double(max(1, h))

            self.drawing = true
            self.setTrayState(.thinking)

            let picked = SettingsManager.shared.pickRandomStyle()

            Task {
                do {
                    let imagePath = try await generateImage(prompt: prompt, style: picked.prompt, aspect: aspect)
                    SettingsManager.shared.addRecent(prompt, imagePath)
                    DispatchQueue.main.async { self.buildMenu() }

                    DispatchQueue.global().async { [weak self] in
                        self?.drawImage(imagePath: imagePath, prompt: prompt, area: area)
                    }
                } catch {
                    self.presentDrawFailure(error: error)
                }
            }
        }
    }

    func runInpaintFlow(prompt: String, area: PickerResult) {
        let w = abs(area.bottomRight.0 - area.topLeft.0)
        let h = abs(area.bottomRight.1 - area.topLeft.1)
        let aspect = Double(w) / Double(max(1, h))

        drawing = true
        setTrayState(.thinking)

        let picked = SettingsManager.shared.pickRandomStyle()
        let stylePrompt = picked.prompt + ". Fill the ENTIRE image edge to edge. No empty space, no margins."

        Task {
            do {
                let imagePath = try await generateImage(prompt: prompt, style: stylePrompt, aspect: aspect)
                SettingsManager.shared.addRecent("[inpaint] \(prompt)", imagePath)
                DispatchQueue.main.async { self.buildMenu() }

                DispatchQueue.global().async { [weak self] in
                    self?.drawImage(imagePath: imagePath, prompt: prompt, area: area)
                }
            } catch {
                presentDrawFailure(error: error)
            }
        }
    }

    /// Surfaces a draw-pipeline failure: full message in an alert (truncated text never fit
    /// in the menu bar anyway) plus a red icon flash for ambient feedback.
    private func presentDrawFailure(error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.flashTrayState(.failed, duration: 3)
            self.drawing = false
            let alert = NSAlert()
            alert.messageText = "Drawing failed"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            if let icon = self.appIcon { alert.icon = icon }
            alert.window.level = .floating
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    func drawImage(imagePath: String, prompt: String, area: PickerResult) {
        let s = SettingsManager.shared.load()
        let w = abs(area.bottomRight.0 - area.topLeft.0)
        let h = abs(area.bottomRight.1 - area.topLeft.1)

        let autoSettings = autoSettingsForImage(path: imagePath, canvasW: w, canvasH: h)
        var ds = settingsFromDict(autoSettings)
        ds.countdown = s.countdown

        // Apply speed
        if s.drawSpeed == "fast" { ds.speed = Int(Double(ds.speed) * 1.8) }
        else if s.drawSpeed == "slow" { ds.speed = Int(Double(ds.speed) * 0.5) }

        // Check accessibility before drawing
        if !checkAccessibilityForDrawing() {
            presentAccessibilityRequiredAlert()
            DispatchQueue.main.async { [weak self] in
                self?.drawing = false
                self?.setTrayState(.idle)
            }
            return
        }

        let narrator = Narrator(prompt: prompt, enabled: s.narratorEnabled)
        startEscapeMonitor()

        // Set up pause handler — shows dialog on main thread, blocks draw thread
        onPauseHandler = {
            narrator.onPaused()
            var resume = false
            let semaphore = DispatchSemaphore(value: 0)
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Drawing paused"
                alert.informativeText = "Press Resume to continue or Cancel to stop."
                alert.addButton(withTitle: "Resume")
                alert.addButton(withTitle: "Cancel drawing")
                alert.window.level = .floating
                NSApp.activate(ignoringOtherApps: true)
                resume = alert.runModal() == .alertFirstButtonReturn
                if resume { narrator.onResumed() }
                semaphore.signal()
            }
            // Avoid blocking the draw thread forever if the main queue never runs the alert (should not happen).
            if semaphore.wait(timeout: .now() + 3600) == .timedOut {
                return false
            }
            return resume
        }

        do {
            try processAndDraw(imagePath: imagePath, topLeft: area.topLeft, bottomRight: area.bottomRight,
                               settings: ds) { [weak self] msg in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if let seconds = self.countdownSeconds(in: msg) {
                        if seconds == ds.countdown { narrator.onStart() }
                        self.setTrayState(.countdown(seconds))
                        return
                    }
                    if let pct = self.drawProgressPercent(in: msg) {
                        self.setTrayState(.drawing(progress: pct))
                        narrator.onProgress(current: pct, total: 100)
                        return
                    }
                    // Unknown engine message — hold whatever state we are already showing;
                    // the menu bar must stay icon-only so we never surface raw text.
                }
            }
            stopEscapeMonitor()
            onPauseHandler = nil
            narrator.onDone()
            DispatchQueue.main.async { [weak self] in
                self?.flashTrayState(.done, duration: 4)
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                    _ = narrator // keep alive for audio
                    self?.drawing = false
                    self?.buildMenu()
                }
            }
        } catch {
            stopEscapeMonitor()
            onPauseHandler = nil
            narrator.onCancelled()
            DispatchQueue.main.async { [weak self] in
                self?.flashTrayState(.cancelled, duration: 4)
                // Keep narrator alive long enough for audio to play
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                    _ = narrator // prevent deallocation
                    self?.drawing = false
                    self?.buildMenu()
                }
            }
        }
    }
}
