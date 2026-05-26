import AppKit

struct PickerResult {
    let topLeft: (Int, Int)
    let bottomRight: (Int, Int)
}

class AreaPickerController {
    private var overlayWindow: NSWindow?
    private var overlayView: PickerOverlayView?
    private var completion: ((PickerResult?) -> Void)?
    private var startPoint: NSPoint = .zero
    private var currentPoint: NSPoint = .zero
    private var dragging = false
    private var monitors: [Any] = []

    func show(completion: @escaping (PickerResult?) -> Void) {
        self.completion = completion
        guard let screen = NSScreen.main else { completion(nil); return }

        let view = PickerOverlayView(frame: screen.frame)
        self.overlayView = view

        let window = NSWindow(contentRect: screen.frame,
                              styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        self.overlayWindow = window

        NSCursor.crosshair.push()

        // Use global event monitors
        let localDown = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.handleMouseDown(event)
            return nil  // consume the event
        }
        let localDrag = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDragged) { [weak self] event in
            self?.handleMouseDragged(event)
            return nil
        }
        let localUp = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            self?.handleMouseUp(event)
            return nil
        }
        let localKey = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Escape
                self?.cancel()
                return nil
            }
            return event
        }

        monitors = [localDown, localDrag, localUp, localKey].compactMap { $0 }
    }

    private func handleMouseDown(_ event: NSEvent) {
        // Convert to screen coordinates
        startPoint = NSEvent.mouseLocation
        currentPoint = startPoint
        dragging = true
        updateOverlay()
    }

    private func handleMouseDragged(_ event: NSEvent) {
        guard dragging else { return }
        currentPoint = NSEvent.mouseLocation
        updateOverlay()
    }

    private func handleMouseUp(_ event: NSEvent) {
        guard dragging else { return }
        dragging = false
        let endPoint = NSEvent.mouseLocation

        // Convert from screen coords (bottom-left origin) to top-left origin
        guard let screenHeight = NSScreen.main?.frame.height else { cancel(); return }

        let x1 = Int(min(startPoint.x, endPoint.x))
        let x2 = Int(max(startPoint.x, endPoint.x))
        let y1 = Int(screenHeight - max(startPoint.y, endPoint.y))
        let y2 = Int(screenHeight - min(startPoint.y, endPoint.y))

        cleanup()

        if x2 - x1 > 10 && y2 - y1 > 10 {
            completion?(PickerResult(topLeft: (x1, y1), bottomRight: (x2, y2)))
        } else {
            completion?(nil)
        }
        completion = nil
    }

    private func cancel() {
        cleanup()
        completion?(nil)
        completion = nil
    }

    private func cleanup() {
        NSCursor.pop()
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors = []
        overlayWindow?.orderOut(nil)
        // Defer window release to avoid autorelease crash
        let win = overlayWindow
        overlayWindow = nil
        overlayView = nil
        DispatchQueue.main.async { _ = win }  // prevent premature dealloc
    }

    private func updateOverlay() {
        overlayView?.selectionRect = dragging ? NSRect(
            x: min(startPoint.x, currentPoint.x),
            y: min(startPoint.y, currentPoint.y),
            width: abs(currentPoint.x - startPoint.x),
            height: abs(currentPoint.y - startPoint.y)
        ) : nil
        overlayView?.needsDisplay = true
    }
}

class PickerOverlayView: NSView {
    var selectionRect: NSRect?

    override func draw(_ dirtyRect: NSRect) {
        // Dark overlay
        NSColor(white: 0, alpha: 0.3).setFill()
        bounds.fill()

        if let rect = selectionRect {
            // Convert screen coords to view coords
            let viewRect = convert(rect, from: nil)

            // Clear selection
            NSColor.clear.setFill()
            viewRect.fill(using: .copy)

            // Blue border
            NSColor(calibratedRed: 0.23, green: 0.51, blue: 0.97, alpha: 0.9).setStroke()
            let path = NSBezierPath(rect: viewRect)
            path.lineWidth = 2
            path.stroke()

            // Dimensions label
            let w = Int(rect.width), h = Int(rect.height)
            let label = "\(w) × \(h)"
            let attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor.white.withAlphaComponent(0.9),
                .font: NSFont.systemFont(ofSize: 12)
            ]
            let size = label.size(withAttributes: attrs)
            label.draw(at: NSPoint(x: viewRect.midX - size.width/2, y: viewRect.maxY + 6), withAttributes: attrs)
        } else {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.85)
            shadow.shadowBlurRadius = 12
            shadow.shadowOffset = NSSize(width: 0, height: -2)

            let title = "Click and drag to choose where to draw"
            let titleAttrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor.white,
                .font: NSFont.systemFont(ofSize: 34, weight: .semibold),
                .shadow: shadow
            ]
            let titleSize = title.size(withAttributes: titleAttrs)

            let hint = "Esc to cancel"
            let hintAttrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor.white.withAlphaComponent(0.75),
                .font: NSFont.systemFont(ofSize: 16, weight: .medium),
                .shadow: shadow
            ]
            let hintSize = hint.size(withAttributes: hintAttrs)

            let gap: CGFloat = 14
            let totalH = titleSize.height + gap + hintSize.height
            let titleY = bounds.midY - totalH/2 + hintSize.height + gap
            let hintY = bounds.midY - totalH/2

            title.draw(at: NSPoint(x: bounds.midX - titleSize.width/2, y: titleY), withAttributes: titleAttrs)
            hint.draw(at: NSPoint(x: bounds.midX - hintSize.width/2, y: hintY), withAttributes: hintAttrs)
        }
    }
}
