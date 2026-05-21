import AppKit

class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var onDone: (() -> Void)?
    private var selectedProvider = "fal.ai"
    private var providerSegment: NSSegmentedControl?
    private var speedSegment: NSSegmentedControl?
    private var keyField: NSSecureTextField?
    private var countdownStepper: NSStepper?
    private var countdownLabel: NSTextField?
    private var hintLabel: NSTextField?
    private var keyLabel: NSTextField?
    private var styleChecks: [NSButton] = []
    private var styleNames: [String] = []
    private var freeModeCheck: NSButton?

    func show(onDone: (() -> Void)? = nil) {
        self.onDone = onDone
        let s = SettingsManager.shared.load()
        // Default to "free" if no API key is saved for any provider
        if SettingsManager.shared.getApiKey(s.provider) != nil {
            self.selectedProvider = s.provider
        } else {
            // Check if any provider has a key
            let hasAnyKey = ["fal.ai", "openai", "gemini"].contains { SettingsManager.shared.getApiKey($0) != nil }
            self.selectedProvider = hasAnyKey ? s.provider : "free"
        }

        let allStyleCount = builtInStyles.count + s.customStyles.count
        let styleRows = (allStyleCount + 1) / 2
        // +28 reserves a row for the "Show in Dock" toggle inserted below the speed/countdown row.
        let windowH = 440 + styleRows * 22 + 40 + 28
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: windowH),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.level = .floating
        w.center()
        w.delegate = self
        w.title = "Settings"
        self.window = w

        let cv = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: windowH))
        let label = NSColor.secondaryLabelColor
        let subtle = NSColor.tertiaryLabelColor
        var y = windowH - 60  // current y position, working downward

        // Description
        let desc = NSTextField(wrappingLabelWithString: "SixFingers uses AI to generate images. Connect your API key from any supported provider to get started.")
        desc.font = .systemFont(ofSize: 12)
        desc.textColor = label
        desc.frame = NSRect(x: 24, y: y - 10, width: 372, height: 32)
        cv.addSubview(desc)
        y -= 52

        // Draw Speed + Countdown (always available, even in Free mode)
        let speedLabel = NSTextField(labelWithString: "Draw Speed")
        speedLabel.font = .systemFont(ofSize: 13, weight: .bold)
        speedLabel.textColor = .labelColor
        speedLabel.frame = NSRect(x: 24, y: y, width: 180, height: 16)
        cv.addSubview(speedLabel)

        let cdLabel = NSTextField(labelWithString: "Countdown")
        cdLabel.font = .systemFont(ofSize: 13, weight: .bold)
        cdLabel.textColor = .labelColor
        cdLabel.frame = NSRect(x: 260, y: y, width: 140, height: 16)
        cv.addSubview(cdLabel)
        y -= 28

        let speedSeg = NSSegmentedControl(labels: ["Slow", "Normal", "Fast"], trackingMode: .selectOne, target: self, action: nil)
        speedSeg.frame = NSRect(x: 24, y: y, width: 210, height: 24)
        let speeds = ["slow", "normal", "fast"]
        speedSeg.selectedSegment = speeds.firstIndex(of: s.drawSpeed) ?? 1
        cv.addSubview(speedSeg)
        self.speedSegment = speedSeg

        let cdValue = NSTextField(frame: NSRect(x: 270, y: y, width: 44, height: 22))
        cdValue.stringValue = "\(s.countdown)"
        cdValue.font = .systemFont(ofSize: 12)
        cdValue.alignment = .center
        cdValue.isBordered = true
        cdValue.isBezeled = true
        cdValue.bezelStyle = .roundedBezel
        cdValue.isEditable = false
        cv.addSubview(cdValue)
        self.countdownLabel = cdValue

        let stepper = NSStepper(frame: NSRect(x: 318, y: y, width: 18, height: 24))
        stepper.minValue = 1; stepper.maxValue = 10; stepper.integerValue = s.countdown
        stepper.target = self; stepper.action = #selector(onStepperChange(_:))
        cv.addSubview(stepper)
        self.countdownStepper = stepper
        y -= 36

        // Show in Dock toggle — live preference, applies immediately without relaunch.
        let dockCheck = NSButton(checkboxWithTitle: "Show in Dock", target: self, action: #selector(onShowInDockToggle(_:)))
        dockCheck.state = UserDefaults.standard.bool(forKey: AppDelegate.showInDockDefaultsKey) ? .on : .off
        dockCheck.frame = NSRect(x: 24, y: y, width: 200, height: 20)
        cv.addSubview(dockCheck)
        let dockHint = NSTextField(labelWithString: "Useful if the menu bar icon is hard to find")
        dockHint.font = .systemFont(ofSize: 11)
        dockHint.textColor = subtle
        dockHint.frame = NSRect(x: 24, y: y - 16, width: 372, height: 14)
        cv.addSubview(dockHint)
        y -= 36

        // AI Provider
        let provLabel = NSTextField(labelWithString: "AI Provider")
        provLabel.font = .systemFont(ofSize: 13, weight: .bold)
        provLabel.textColor = .labelColor
        provLabel.frame = NSRect(x: 24, y: y, width: 372, height: 16)
        cv.addSubview(provLabel)
        y -= 28

        let provSeg = NSSegmentedControl(labels: ["None", "fal.ai", "OpenAI", "Gemini"], trackingMode: .selectOne, target: self, action: #selector(onProviderChange(_:)))
        provSeg.frame = NSRect(x: 24, y: y, width: 372, height: 24)
        let provIds = ["free", "fal.ai", "openai", "gemini"]
        provSeg.selectedSegment = provIds.firstIndex(of: selectedProvider) ?? 0
        cv.addSubview(provSeg)
        self.providerSegment = provSeg
        y -= 18

        let hint = NSTextField(labelWithString: "")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = subtle
        hint.frame = NSRect(x: 24, y: y, width: 372, height: 12)
        cv.addSubview(hint)
        self.hintLabel = hint
        updateHint()
        y -= 20

        // API Key — more top margin
        y -= 6
        let isFree = selectedProvider == "free"
        let providerName = providers[selectedProvider]?.label ?? "API"
        let kl = NSTextField(labelWithString: isFree ? "API Key" : "\(providerName) API Key")
        kl.font = .systemFont(ofSize: 13, weight: .bold)
        kl.textColor = .labelColor
        kl.frame = NSRect(x: 24, y: y, width: 372, height: 16)
        cv.addSubview(kl)
        self.keyLabel = kl
        y -= 28

        let kf = NSSecureTextField(frame: NSRect(x: 24, y: y, width: 372, height: 22))
        kf.placeholderString = "Enter API key..."
        kf.font = .systemFont(ofSize: 12)
        kf.isEnabled = !isFree
        kf.stringValue = isFree ? "" : (SettingsManager.shared.getApiKey(selectedProvider) ?? "")
        cv.addSubview(kf)
        self.keyField = kf
        y -= 26

        let sec = NSTextField(labelWithString: "Stored locally on your Mac. Never shared.")
        sec.font = .systemFont(ofSize: 11)
        sec.textColor = subtle
        sec.frame = NSRect(x: 24, y: y + 6, width: 372, height: 12)
        cv.addSubview(sec)
        y += 4  // less bottom margin

        // Styles section
        y -= 36

        // (Free mode is now part of the provider picker)

        let stylesLabel = NSTextField(labelWithString: "Styles")
        stylesLabel.font = .systemFont(ofSize: 13, weight: .bold)
        stylesLabel.textColor = .labelColor
        stylesLabel.frame = NSRect(x: 24, y: y, width: 200, height: 16)
        cv.addSubview(stylesLabel)

        let stylesHint = NSTextField(labelWithString: "Randomly picks from enabled")
        stylesHint.font = .systemFont(ofSize: 11)
        stylesHint.textColor = subtle
        stylesHint.frame = NSRect(x: 24, y: y - 18, width: 372, height: 14)
        cv.addSubview(stylesHint)
        y -= 40

        let builtInNames = builtInStyles.map { $0.0 }
        let customNames = s.customStyles.keys.sorted()
        styleNames = builtInNames + customNames
        styleChecks = []

        // Two columns
        let colW = 170
        for (i, name) in styleNames.enumerated() {
            let col = i % 2
            let row = i / 2
            let check = NSButton(checkboxWithTitle: name, target: nil, action: nil)
            check.frame = NSRect(x: 28 + col * colW, y: y - row * 22, width: colW, height: 20)
            check.state = s.enabledStyles.contains(name) ? .on : .off
            cv.addSubview(check)
            styleChecks.append(check)
        }
        let rows = (styleNames.count + 1) / 2
        y -= rows * 22

        // Disable styles if None/free mode on initial load
        if isFree {
            for check in styleChecks { check.isEnabled = false }
        }

        y -= 8
        let addBtn = NSButton(title: "+ Add Custom Style", target: self, action: #selector(onAddCustomStyle))
        addBtn.bezelStyle = .inline
        addBtn.frame = NSRect(x: 24, y: y, width: 140, height: 22)
        cv.addSubview(addBtn)

        if !s.customStyles.isEmpty {
            let clearBtn = NSButton(title: "Clear Custom Styles", target: self, action: #selector(onClearCustomStyles))
            clearBtn.bezelStyle = .inline
            clearBtn.frame = NSRect(x: 172, y: y, width: 140, height: 22)
            cv.addSubview(clearBtn)
        }

        // Save button
        let saveBtn = NSButton(title: "Save", target: self, action: #selector(onSave))
        saveBtn.bezelStyle = .rounded
        saveBtn.keyEquivalent = "\r"
        saveBtn.frame = NSRect(x: 316, y: 20, width: 80, height: 30)
        cv.addSubview(saveBtn)

        w.contentView = cv
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)  // hide instead of close
        return false  // prevent actual close/dealloc
    }

    private func updateHint() {
        if let info = providers[selectedProvider] {
            hintLabel?.stringValue = "Get one at \(info.keyUrl)"
        }
    }

    @objc func onProviderChange(_ sender: NSSegmentedControl) {
        // Save current key before switching
        let currentKey = keyField?.stringValue ?? ""
        if !currentKey.isEmpty && selectedProvider != "free" {
            SettingsManager.shared.setApiKey(selectedProvider, key: currentKey)
        }

        let provIds = ["free", "fal.ai", "openai", "gemini"]
        selectedProvider = provIds[sender.selectedSegment]
        let isFree = selectedProvider == "free"

        if isFree {
            keyLabel?.stringValue = "API Key"
            keyField?.stringValue = ""
            keyField?.placeholderString = ""
            keyField?.isEnabled = false
            hintLabel?.stringValue = ""
        } else {
            let providerName = providers[selectedProvider]?.label ?? selectedProvider
            keyLabel?.stringValue = "\(providerName) API Key"
            keyField?.isEnabled = true
            keyField?.placeholderString = "Enter API key..."
            keyField?.stringValue = SettingsManager.shared.getApiKey(selectedProvider) ?? ""
            updateHint()
        }

        for check in styleChecks { check.isEnabled = !isFree }
    }

    @objc func onClearCustomStyles() {
        let confirm = NSAlert()
        confirm.messageText = "Clear all custom styles?"
        confirm.informativeText = "This cannot be undone."
        confirm.addButton(withTitle: "Clear")
        confirm.addButton(withTitle: "Cancel")
        confirm.alertStyle = .warning
        if let icon = (NSApp.delegate as? AppDelegate)?.appIcon { confirm.icon = icon }

        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        var s = SettingsManager.shared.load()
        s.customStyles = [:]
        s.enabledStyles = s.enabledStyles.filter { builtInStyles.map({ $0.0 }).contains($0) }
        if s.enabledStyles.isEmpty { s.enabledStyles = ["Default"] }
        SettingsManager.shared.save(s)

        // Refresh
        window?.orderOut(nil)
        show(onDone: onDone)
    }

    @objc func onAddCustomStyle() {
        let alert = NSAlert()
        alert.messageText = "New Custom Style"
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 56))
        let nameField = NSTextField(frame: NSRect(x: 0, y: 30, width: 300, height: 22))
        nameField.placeholderString = "Style name (e.g. Watercolor)"
        accessory.addSubview(nameField)
        let promptField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 22))
        promptField.placeholderString = "Style prompt..."
        accessory.addSubview(promptField)
        alert.accessoryView = accessory
        alert.window.level = .floating

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        let prompt = promptField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty && !prompt.isEmpty else { return }

        var s = SettingsManager.shared.load()
        s.customStyles[name] = prompt
        s.enabledStyles.append(name)
        SettingsManager.shared.save(s)

        // Refresh settings window
        window?.orderOut(nil)
        show(onDone: onDone)
    }

    @objc func onStepperChange(_ sender: NSStepper) {
        countdownLabel?.stringValue = "\(sender.integerValue)"
    }

    @objc func onShowInDockToggle(_ sender: NSButton) {
        (NSApp.delegate as? AppDelegate)?.setShowInDock(sender.state == .on)
    }

    @objc func onSave() {
        var s = SettingsManager.shared.load()
        s.provider = selectedProvider
        let key = keyField?.stringValue ?? ""
        if selectedProvider != "free" {
            SettingsManager.shared.setApiKey(selectedProvider, key: key)
        }

        let speeds = ["slow", "normal", "fast"]
        if let idx = speedSegment?.selectedSegment, idx >= 0 && idx < speeds.count {
            s.drawSpeed = speeds[idx]
        }
        s.countdown = countdownStepper?.integerValue ?? 5

        // Save enabled styles
        var enabled: [String] = []
        for (i, name) in styleNames.enumerated() {
            if i < styleChecks.count && styleChecks[i].state == .on {
                enabled.append(name)
            }
        }
        if enabled.isEmpty { enabled = ["Default"] }
        s.enabledStyles = enabled

        SettingsManager.shared.save(s)
        window?.orderOut(nil)  // hide instead of close — avoids autorelease crash
        onDone?()
    }
}
