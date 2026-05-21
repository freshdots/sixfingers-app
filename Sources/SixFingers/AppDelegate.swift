import AppKit

struct PromptResult {
    enum Kind { case text, file }
    let type: Kind
    let value: String
}

final class AppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
    var statusItem: NSStatusItem!
    var drawing = false
    let settingsController = SettingsWindowController()
    var pickerController: AreaPickerController?  // retain picker

    var appIcon: NSImage?

    /// Polls `AXIsProcessTrusted` after we send the user to Accessibility settings; never runs unbounded.
    private var accessibilityTrustTimer: Timer?
    private var accessibilityWaitStarted: Date?
    private var lastAccessibilityStatusSecond: Int = -1

    private enum AccessibilityPolling {
        static let interval: TimeInterval = 1
        static let maxWaitSeconds: TimeInterval = 30
        static let statusEverySeconds = 10
    }

    static let welcomeSheetSeenVersionKey = "welcomeSheetSeenForVersion"
    /// Bump when onboarding copy changes meaningfully so existing users see the new sheet once.
    static let currentWelcomeSheetVersion = 2

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

        // Always show in the Dock alongside the menu bar icon.
        NSApp.setActivationPolicy(.regular)

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
                    loaded = true
                    break
                }
            }
            if !loaded {
                button.title = "🖋"
            }
        }

        buildMenu()

        // First launch: introduce the app, then check permissions, then open Draw.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            self.showWelcomeSheetIfNeeded()
            if !checkAccessibilityForDrawing() {
                // Show permission request dialog that waits
                self.showPermissionDialog()
            } else if SettingsManager.shared.getApiKey() == nil {
                self.onDraw()
            }
        }
    }

    /// Right-clicking the dock icon mirrors the menu-bar dropdown minus the Quit row —
    /// macOS already appends its own Quit item to dock menus.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        populateMenuItems(into: menu, includeQuit: false)
        return menu
    }

    /// One-time onboarding sheet. Version-bumped so future copy changes can re-show
    /// without retroactively forcing it on users who already dismissed an older version.
    private func showWelcomeSheetIfNeeded() {
        let seen = UserDefaults.standard.integer(forKey: AppDelegate.welcomeSheetSeenVersionKey)
        if seen >= AppDelegate.currentWelcomeSheetVersion { return }

        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Welcome to SixFingers"
        alert.informativeText = "SixFingers lives in your menu bar and Dock. Press ⌥⇧6 anywhere to start a draw, or click the Dock icon."
        alert.addButton(withTitle: "Got it")
        alert.alertStyle = .informational
        if let icon = appIcon { alert.icon = icon }
        alert.window.level = .floating
        alert.runModal()

        UserDefaults.standard.set(AppDelegate.currentWelcomeSheetVersion, forKey: AppDelegate.welcomeSheetSeenVersionKey)
    }

    func applicationWillTerminate(_ notification: Notification) {
        accessibilityTrustTimer?.invalidate()
        accessibilityTrustTimer = nil
    }

    func setStatus(_ text: String) {
        DispatchQueue.main.async {
            guard let button = self.statusItem.button else { return }
            if text.isEmpty {
                button.title = ""
                button.image?.isTemplate = true  // just show icon
            } else {
                button.title = " \(text)"  // space before text for padding from icon
            }
        }
    }

    func buildMenu() {
        let menu = NSMenu()
        populateMenuItems(into: menu, includeQuit: true)
        statusItem.menu = menu
    }

    /// Shared item layout for the menu-bar dropdown and the dock right-click menu.
    /// The dock menu skips Quit because macOS appends its own.
    private func populateMenuItems(into menu: NSMenu, includeQuit: Bool) {
        let settings = SettingsManager.shared.load()

        let drawItem = NSMenuItem(title: "Draw...", action: #selector(onDraw), keyEquivalent: "")
        drawItem.target = self
        menu.addItem(drawItem)

        menu.addItem(.separator())

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

        let narratorItem = NSMenuItem(title: "Narrator", action: #selector(onToggleNarrator(_:)), keyEquivalent: "")
        narratorItem.target = self
        narratorItem.state = settings.narratorEnabled ? .on : .off
        menu.addItem(narratorItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(onSettings), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let aboutItem = NSMenuItem(title: "About", action: #selector(onAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        if includeQuit {
            menu.addItem(.separator())
            let quitItem = NSMenuItem(title: "Quit", action: #selector(onQuit), keyEquivalent: "q")
            quitItem.target = self
            menu.addItem(quitItem)
        }
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

        setStatus("Drag area to draw \(name)")
        showPicker { [weak self] area in
            guard let self, let area else { self?.setStatus(""); return }
            self.drawing = true
            DispatchQueue.global().async { [weak self] in
                self?.drawImage(imagePath: chosen, prompt: name, area: area)
            }
        }
    }

    func runInpaintFromPrompt(prompt: String) {
        setStatus("Drag over existing drawing")
        showPicker { [weak self] area in
            guard let self, let area else { self?.setStatus(""); return }
            self.runInpaintFlow(prompt: prompt, area: area)
        }
    }

    @objc func onRecent(_ sender: NSMenuItem) {
        guard !drawing, let entry = sender.representedObject as? RecentEntry else { return }
        if !checkAccessibilityForDrawing() {
            presentAccessibilityRequiredAlert()
            return
        }
        setStatus("Drag area to draw in")
        showPicker { [weak self] area in
            guard let self, let area else { self?.setStatus(""); return }
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
        setStatus(name)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.setStatus("") }
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

    private func presentAttentionAlert(messageText: String, informativeText: String, completion: @escaping () -> Void) {
        NSApp.activate(ignoringOtherApps: true)
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

    /// Clicking the dock icon (or reopening via Finder/Spotlight) starts a new draw flow.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        onDraw()
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
        alert.messageText = "SixFingers needs Accessibility access"
        alert.informativeText = "This lets SixFingers draw with your mouse."
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
        setStatus("Waiting for permission…")

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
                self.setStatus("Waiting… \(sec)s (Accessibility)")
            }
        }
        accessibilityTrustTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func handleAccessibilityTrustGranted() {
        presentAttentionAlert(
            messageText: "Accessibility enabled",
            informativeText: "SixFingers stays in your menu bar and Dock. Click the Dock icon or press ⌥⇧6 anywhere to start a draw."
        ) { [weak self] in
            guard let self else { return }
            self.setStatus("Accessibility on — menu bar → Draw…")
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                self?.setStatus("")
            }
            if SettingsManager.shared.getApiKey() == nil {
                self.onDraw()
            }
        }
    }

    private func handleAccessibilityTrustWaitTimedOut() {
        setStatus("")
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Still waiting for Accessibility"
        alert.informativeText =
            "macOS has not granted trust to this build after \(Int(AccessibilityPolling.maxWaitSeconds)) seconds.\n\n\(accessibilityExecutablePathForHelp())\n\nCommon cause: Accessibility is ON for /Applications/SixFingers.app but we are running from dist (or the opposite). Those are separate paths; turn ON the row that matches the path above, or remove both SixFingers entries and add only this app.\n\nAd-hoc rebuilds also change the signature: remove SixFingers with −, quit us, reopen from this path, enable again; or run: tccutil reset Accessibility com.dotfunlabs.sixfingers\n\nYou can keep waiting if permissions are still updating."
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
            setStatus("Use menu → Draw when Accessibility is on")
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                self?.setStatus("")
            }
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
        setStatus("Listening (6s)...")
        let audioPath = recordAudio(duration: 6)
        if let audioPath = audioPath {
            setStatus("Transcribing...")
            Task {
                do {
                    let transcript = try await transcribeAudio(audioPath: audioPath)
                    try? FileManager.default.removeItem(atPath: audioPath)
                    DispatchQueue.main.async { [weak self] in
                        self?.setStatus("")
                        if !transcript.isEmpty { self?.showDrawWithText(transcript) }
                    }
                } catch {
                    try? FileManager.default.removeItem(atPath: audioPath)
                    DispatchQueue.main.async { [weak self] in
                        self?.setStatus("Failed")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self?.setStatus("") }
                    }
                }
            }
        } else {
            setStatus("")
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
            setStatus("Drag area to draw in")
            showPicker { [weak self] area in
                guard let self, let area else { self?.setStatus(""); return }
                self.drawing = true
                DispatchQueue.global().async { [weak self] in
                    self?.drawImage(imagePath: result.value, prompt: "your image", area: area)
                }
            }
            return
        }

        let prompt = result.value
        setStatus("Drag area to draw in")
        showPicker { [weak self] area in
            guard let self, let area else { self?.setStatus(""); return }
            let w = abs(area.bottomRight.0 - area.topLeft.0)
            let h = abs(area.bottomRight.1 - area.topLeft.1)
            let aspect = Double(w) / Double(max(1, h))

            self.drawing = true
            self.setStatus("Thinking...")

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
                    self.setStatus(String(error.localizedDescription.prefix(25)))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.setStatus(""); self.drawing = false }
                }
            }
        }
    }

    func runInpaintFlow(prompt: String, area: PickerResult) {
        let w = abs(area.bottomRight.0 - area.topLeft.0)
        let h = abs(area.bottomRight.1 - area.topLeft.1)
        let aspect = Double(w) / Double(max(1, h))

        drawing = true
        setStatus("Thinking...")

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
                setStatus(String(error.localizedDescription.prefix(25)))
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.setStatus(""); self.drawing = false }
            }
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
                self?.setStatus("")
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
                    if msg.contains("Drawing in") && msg.contains("s") {
                        if msg.contains("\(ds.countdown)s") { narrator.onStart() }
                    }
                    if let match = msg.range(of: #"Drawing (\d+)%"#, options: .regularExpression) {
                        let pct = msg[match].filter { $0.isNumber }
                        self?.setStatus("Drawing \(pct)%")
                        if let p = Int(pct) {
                            narrator.onProgress(current: p, total: 100)
                        }
                    } else {
                        self?.setStatus(String(msg.prefix(20)))
                    }
                }
            }
            stopEscapeMonitor()
            onPauseHandler = nil
            narrator.onDone()
            DispatchQueue.main.async { [weak self] in
                self?.setStatus("Done!")
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                    _ = narrator // keep alive for audio
                    self?.setStatus("")
                    self?.drawing = false
                    self?.buildMenu()
                }
            }
        } catch {
            stopEscapeMonitor()
            onPauseHandler = nil
            narrator.onCancelled()
            DispatchQueue.main.async { [weak self] in
                self?.setStatus("Cancelled")
                // Keep narrator alive long enough for audio to play
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                    _ = narrator // prevent deallocation
                    self?.setStatus("")
                    self?.drawing = false
                    self?.buildMenu()
                }
            }
        }
    }
}
