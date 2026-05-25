import AppKit
import CoreText
import HotKey

struct PromptResult {
    enum Kind { case text, file }
    let type: Kind
    let value: String
}

/// What we composite onto the hand glyph for a given state. The hand is always the
/// base; an overlay is knocked out of it so the menu bar background shows through.
/// `.text` is drawn in Silkscreen at the same size/position regardless of content,
/// so the cancel "X" lines up with the countdown digits. `.pixelCheck` is a hand-
/// rendered checkmark on the same pixel grid as the Silkscreen digits — Silkscreen
/// itself ships no check glyph, so we draw one that matches the font's aesthetic.
enum TrayOverlay: Equatable {
    case text(String)
    case pixelCheck
    case pixelLock
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
    /// `.waitingPermission` deliberately uses a static lock glyph instead of the
    /// elapsed-seconds digit (EAR-45): users read any digit in this slot as a
    /// draw countdown, so the permission-wait state must never expose one.
    var iconOverlay: TrayOverlay? {
        switch self {
        case .countdown(let n): return .text("\(n)")
        case .waitingPermission: return .pixelLock
        case .done: return .pixelCheck
        case .failed: return .text("X")
        case .cancelled: return .text("X")
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

    /// Carbon-backed global hotkey for `KeyBinding.draw`. Carbon is focus-independent,
    /// unlike `NSEvent.addGlobalMonitorForEvents`, which drops events on focus changes.
    private var drawHotKey: HotKey?

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

    static let welcomeSheetSeenVersionKey = "welcomeSheetSeenForVersion"
    /// Bump when onboarding copy changes meaningfully so existing users see the new sheet once.
    static let currentWelcomeSheetVersion = 4

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

        // Register Silkscreen so the tray digit badge can render in our pixel font.
        // Both weights ship under Resources/fonts/ so installers never need the font preinstalled.
        registerBundledFont(named: "Silkscreen-Regular", ext: "ttf")
        registerBundledFont(named: "Silkscreen-Bold", ext: "ttf")

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
                    baseTrayIcon = img
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
        registerDrawHotKey()

        // First launch: introduce the app, then check permissions. The welcome sheet
        // is the single onboarding surface — don't chain into onDraw afterwards or the
        // user gets a second dialog stacked on top of the one they just dismissed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            self.showWelcomeSheetIfNeeded()
            if !checkAccessibilityForDrawing() {
                // Show permission request dialog that waits
                self.showPermissionDialog()
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
    ///
    /// Two paths, no dead-end: either the user already has a drawing app open and we
    /// step out of the way, or we drop them straight into Kleki (free in-browser canvas)
    /// so the next ⌥⇧6 press has somewhere to draw.
    private func showWelcomeSheetIfNeeded() {
        let seen = UserDefaults.standard.integer(forKey: AppDelegate.welcomeSheetSeenVersionKey)
        if seen >= AppDelegate.currentWelcomeSheetVersion { return }

        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Welcome to SixFingers"
        alert.informativeText = "SixFingers lives in your menu bar and Dock. Press ⌥⇧6 anywhere to draw into whatever app is in front — Photoshop, Procreate, or a free in-browser canvas."
        // First button is the rightmost / default — keep "Open free drawing app" primary
        // so users without a drawing app reach a working canvas in one click. The secondary
        // label is past-tense ("I have my app open") so the user knows the precondition
        // before they're dropped into canvas selection.
        alert.addButton(withTitle: "Open free drawing app")
        alert.addButton(withTitle: "I have my app open")
        alert.alertStyle = .informational
        if let icon = appIcon { alert.icon = icon }
        alert.window.level = .floating
        let response = alert.runModal()

        if response == .alertFirstButtonReturn, let url = URL(string: "https://kleki.com/") {
            NSWorkspace.shared.open(url)
        }

        UserDefaults.standard.set(AppDelegate.currentWelcomeSheetVersion, forKey: AppDelegate.welcomeSheetSeenVersionKey)
    }

    func applicationWillTerminate(_ notification: Notification) {
        accessibilityTrustTimer?.invalidate()
        accessibilityTrustTimer = nil
        drawHotKey = nil
    }

    private func registerDrawHotKey() {
        let binding = KeyBinding.draw
        let hotKey = HotKey(key: binding.key, modifiers: binding.modifiers)
        hotKey.keyDownHandler = { [weak self] in
            DispatchQueue.main.async { self?.onDraw() }
        }
        drawHotKey = hotKey
    }

    /// Locate a font shipped under `Resources/fonts/` and register it with the process so
    /// `NSFont(name:size:)` can find it. We try the packaged-app layout first
    /// (`Contents/Resources/fonts/…`), then dev-mode locations relative to the running binary
    /// and cwd so `swift run` from the repo root also picks up the font.
    private func registerBundledFont(named name: String, ext: String) {
        let exeDir = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
            .deletingLastPathComponent()
        // `swift run` produces .build/<triple>/<config>/<bin>; the repo root sits three levels above the bin dir.
        let repoRootFromExe = exeDir
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let candidates: [String] = [
            // Packaged .app: rsync drops Resources/* into Contents/Resources/, so fonts/ sits directly there.
            Bundle.main.resourcePath.map { "\($0)/fonts/\(name).\(ext)" },
            Bundle.main.resourcePath.map { "\($0)/Resources/fonts/\(name).\(ext)" },
            // `swift run` from the repo root.
            "Resources/fonts/\(name).\(ext)",
            // `swift run` from anywhere — resolve relative to the binary in .build/<triple>/<config>/.
            repoRootFromExe.appendingPathComponent("Resources/fonts/\(name).\(ext)").path,
        ].compactMap { $0 }

        for path in candidates {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let url = URL(fileURLWithPath: path) as CFURL
            var cfError: Unmanaged<CFError>?
            let ok = CTFontManagerRegisterFontsForURL(url, .process, &cfError)
            if !ok, let err = cfError?.takeRetainedValue() {
                // Re-registering an already-registered URL reports an error; ignore so a
                // second `applicationDidFinishLaunching` (tests, fast relaunch) stays silent.
                let code = CFErrorGetCode(err)
                if code != CTFontManagerError.alreadyRegistered.rawValue {
                    fputs("SixFingers: failed to register \(name).\(ext): \(err)\n", stderr)
                }
            }
            return
        }
        fputs("SixFingers: bundled font \(name).\(ext) not found in any known location\n", stderr)
    }

    /// Safety net so we never freeze on a countdown digit if the engine forgets to
    /// emit its post-countdown "Drawing..." (or the regex misses a future variant).
    /// Armed whenever we enter `.countdown(_)`; fires ~1.3s after the last expected
    /// tick and flips us into `.drawing(progress: nil)` if we're still showing a
    /// countdown.
    private var countdownWatchdog: DispatchWorkItem?

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
        armCountdownWatchdogIfNeeded(for: next)
    }

    /// (Re)schedules the stuck-countdown safety net. Each countdown tick resets the
    /// timer so a 5→4→3→2→1 sequence only ever has one outstanding watchdog. Any
    /// non-countdown state cancels the watchdog outright.
    private func armCountdownWatchdogIfNeeded(for next: TrayState) {
        countdownWatchdog?.cancel()
        countdownWatchdog = nil
        guard case .countdown(let n) = next else { return }
        // Each tick rearms the timer, so we only need cover from this tick: one
        // second to the next expected tick plus a grace window for the engine to
        // emit "Drawing..." or its first progress message.
        let delay = Double(max(n, 1)) + 1.3
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if case .countdown = self.state {
                self.setTrayState(.drawing(progress: nil))
            }
        }
        countdownWatchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
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
    /// (Silkscreen text or pixel-art check). The template flag is flipped off whenever we apply
    /// an explicit tint so the color survives the menu bar's auto-tinting.
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
        case .text(let value):
            let text = value as NSString
            // Silkscreen is a pixel/bitmap font — bundled via registerBundledFont(named:ext:).
            // The system-font fallback only fires if registration failed for some reason.
            let font = NSFont(name: "Silkscreen", size: 12)
                ?? NSFont.systemFont(ofSize: 11, weight: .heavy)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.black,
            ]
            let textSize = text.size(withAttributes: attrs)
            let textRect = NSRect(
                x: (rect.width - textSize.width) / 2,
                y: (rect.height - textSize.height) / 2 - 3,
                width: textSize.width,
                height: textSize.height
            )
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            text.draw(in: textRect, withAttributes: attrs)
            NSGraphicsContext.current?.compositingOperation = .sourceOver
        case .pixelCheck:
            drawPixelCheckKnockout(in: rect)
        case .pixelLock:
            drawPixelLockKnockout(in: rect)
        }
    }

    /// Hand-rendered checkmark on a 2-point pixel grid. Silkscreen has no check glyph,
    /// so we approximate one in the same blocky style. Grid origin is the icon centre,
    /// shifted down 3pt to match the Silkscreen digit y-offset.
    private func drawPixelCheckKnockout(in rect: NSRect) {
        let pixel: CGFloat = 2
        // (col, row) pairs forming the check shape on a 7×5 grid. Row 0 is the bottom-left
        // corner of the glyph; column 0 is its left edge. Two short pixels go down-right
        // into the elbow, then five pixels climb up-right.
        let cells: [(Int, Int)] = [
            (0, 3), (1, 2),
            (2, 1), (3, 2),
            (4, 3), (5, 4), (6, 5),
        ]
        let glyphCols = 7
        let glyphRows = 6
        let glyphWidth = CGFloat(glyphCols) * pixel
        let glyphHeight = CGFloat(glyphRows) * pixel
        let originX = (rect.width - glyphWidth) / 2
        let originY = (rect.height - glyphHeight) / 2 - 3
        NSGraphicsContext.current?.compositingOperation = .destinationOut
        NSColor.black.setFill()
        for (col, row) in cells {
            let cell = NSRect(
                x: originX + CGFloat(col) * pixel,
                y: originY + CGFloat(row) * pixel,
                width: pixel,
                height: pixel
            )
            cell.fill()
        }
        NSGraphicsContext.current?.compositingOperation = .sourceOver
    }

    /// Hand-rendered padlock on the same 2-point pixel grid as `drawPixelCheckKnockout`.
    /// Used as the permission-waiting overlay so the icon reads as "blocked / no access"
    /// instead of a draw countdown (EAR-45). Sized and positioned to live in the *palm*
    /// area — same center point and visual weight as the countdown digit overlay — so
    /// the lock reads as the same kind of in-palm status indicator the countdown is,
    /// not a corner badge. Footprint matches a single Silkscreen digit (~6×10pt), so
    /// the hand silhouette stays the dominant shape. Shape on a 3×5 grid: shackle arc
    /// on top two rows, body below with a one-pixel keyhole gap.
    private func drawPixelLockKnockout(in rect: NSRect) {
        let pixel: CGFloat = 2
        let cells: [(Int, Int)] = [
            (1, 4),
            (0, 3),         (2, 3),
            (0, 2), (1, 2), (2, 2),
            (0, 1),         (2, 1),
            (0, 0), (1, 0), (2, 0),
        ]
        let glyphCols = 3
        let glyphRows = 5
        let glyphWidth = CGFloat(glyphCols) * pixel
        let glyphHeight = CGFloat(glyphRows) * pixel
        // Centred in the palm area with the same -3pt y-nudge the countdown text uses,
        // so the lock's center point matches the digit's center point exactly.
        let originX = (rect.width - glyphWidth) / 2
        let originY = (rect.height - glyphHeight) / 2 - 3
        NSGraphicsContext.current?.compositingOperation = .destinationOut
        NSColor.black.setFill()
        for (col, row) in cells {
            let cell = NSRect(
                x: originX + CGFloat(col) * pixel,
                y: originY + CGFloat(row) * pixel,
                width: pixel,
                height: pixel
            )
            cell.fill()
        }
        NSGraphicsContext.current?.compositingOperation = .sourceOver
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

        // Draw — keyEquivalent here is for *display only*; the system-wide trigger
        // lives in `drawHotKey` so it fires even when the menu is closed.
        let drawBinding = KeyBinding.draw
        let drawItem = NSMenuItem(
            title: "Draw...",
            action: #selector(onDraw),
            keyEquivalent: drawBinding.menuKeyEquivalent
        )
        drawItem.keyEquivalentModifierMask = drawBinding.modifiers
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

        // No API key yet — mirror the EAR-47 welcome-sheet button design so we only
        // have one onboarding vocabulary across the app. Without a key the only thing
        // we can draw is a bundled sample; both buttons route there, the difference is
        // whether we open Kleki first or assume the user's app is already in front.
        if SettingsManager.shared.getApiKey() == nil {
            let noKey = NSAlert()
            noKey.messageText = "SixFingers"
            noKey.informativeText = "Draws anything you can imagine, right where your cursor is."
            noKey.addButton(withTitle: "Open free drawing app")
            noKey.addButton(withTitle: "I have my app open")
            if let icon = appIcon { noKey.icon = icon }
            noKey.window.level = .floating
            NSApp.activate(ignoringOtherApps: true)

            let r = noKey.runModal()
            if r == .alertFirstButtonReturn, let url = URL(string: "https://kleki.com/") {
                NSWorkspace.shared.open(url)
            }
            drawRandomImage()
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
            alert.messageText = "SixFingers needs Accessibility access"
            alert.informativeText = "Turn on SixFingers in System Settings → Privacy & Security → Accessibility to start drawing."
            alert.addButton(withTitle: "Open Settings")
            alert.addButton(withTitle: "Cancel")
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
        alert.messageText = "Allow SixFingers to control your mouse?"
        alert.informativeText = "SixFingers needs Accessibility access to draw on your screen. Turn it on in System Settings, then come back here to start drawing."
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Quit")
        if let icon = appIcon { alert.icon = icon }
        alert.window.level = .floating
        NSApp.activate(ignoringOtherApps: true)

        let response = alert.runModal()
        if response == .alertSecondButtonReturn {
            NSApp.terminate(nil)
            return
        }

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
        // First-launch only path — the welcome sheet already gave the user a choice
        // ("Open free drawing app" / "I have my app open") and that choice has already
        // run. Routing through `onDraw()` here would re-render the same two buttons via
        // the no-API-key branch, which reads to the user as the welcome dialog popping
        // up a second time. Jump straight to the sample-draw picker (or the prompt
        // window if a key is set up) instead.
        setTrayState(.idle)
        NSApp.activate(ignoringOtherApps: true)
        if SettingsManager.shared.getApiKey() == nil {
            drawRandomImage()
        } else {
            onDraw()
        }
    }

    private func handleAccessibilityTrustWaitTimedOut() {
        setTrayState(.idle)
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Still waiting for Accessibility"
        alert.informativeText = "Once SixFingers is turned on in Privacy & Security → Accessibility, we'll start drawing automatically."
        alert.addButton(withTitle: "Keep Waiting")
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")
        if let icon = appIcon { alert.icon = icon }
        alert.alertStyle = .informational
        alert.window.level = .floating

        let r = alert.runModal()
        switch r {
        case .alertFirstButtonReturn:
            startAccessibilityTrustPolling()
        case .alertSecondButtonReturn:
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
                    // The engine emits "Drawing..." right after the countdown (and again
                    // after a resume) but before the first progress %. Without this we
                    // would freeze on `.countdown(1)` until the first 5-polyline tick.
                    if msg == "Drawing..." {
                        self.setTrayState(.drawing(progress: nil))
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
