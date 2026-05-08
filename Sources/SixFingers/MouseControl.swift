import CoreGraphics
import Foundation

enum MouseControl {
    static func moveTo(_ x: Double, _ y: Double) {
        let point = CGPoint(x: x, y: y)
        let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                           mouseCursorPosition: point, mouseButton: .left)
        event?.post(tap: .cghidEventTap)
    }

    static func smoothMoveTo(_ x: Double, _ y: Double, durationMs: Double) {
        let current = position()
        let steps = max(2, Int(durationMs / 2)) // ~2ms per step
        let dx = (x - current.x) / Double(steps)
        let dy = (y - current.y) / Double(steps)
        let sleepUs = UInt32(max(500, (durationMs * 1000) / Double(steps)))

        for i in 1...steps {
            let px = current.x + dx * Double(i)
            let py = current.y + dy * Double(i)
            let event = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged,
                               mouseCursorPosition: CGPoint(x: px, y: py), mouseButton: .left)
            event?.post(tap: .cghidEventTap)
            usleep(sleepUs)
        }
    }

    static func mouseDown() {
        let pos = position()
        let event = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                           mouseCursorPosition: pos, mouseButton: .left)
        event?.post(tap: .cghidEventTap)
    }

    static func mouseUp() {
        let pos = position()
        let event = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                           mouseCursorPosition: pos, mouseButton: .left)
        event?.post(tap: .cghidEventTap)
    }

    static func position() -> CGPoint {
        return CGEvent(source: nil)?.location ?? .zero
    }

    static func testMouseControl() -> Bool {
        let before = position()
        let testX = before.x + 50
        let testY = before.y + 50
        moveTo(testX, testY)
        usleep(50000)
        let after = position()
        moveTo(before.x, before.y)
        return abs(after.x - testX) < 5 && abs(after.y - testY) < 5
    }
}
