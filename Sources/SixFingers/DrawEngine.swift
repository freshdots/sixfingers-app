import AppKit
import ApplicationServices
import Foundation

class DrawCancelled: Error {}

// Global escape key monitoring
private var escapeMonitor: Any?

func startEscapeMonitor() {
    escapePressed = false
    escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
        if event.keyCode == 53 { // Escape
            escapePressed = true
        }
    }
    // Also monitor local events (when app is focused)
    let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
        if event.keyCode == 53 { escapePressed = true }
        return event
    }
    if let l = local {
        escapeMonitor = [escapeMonitor as Any, l]
    }
}

func stopEscapeMonitor() {
    if let monitors = escapeMonitor as? [Any] {
        for m in monitors { NSEvent.removeMonitor(m) }
    } else if let m = escapeMonitor {
        NSEvent.removeMonitor(m)
    }
    escapeMonitor = nil
    escapePressed = false
}

func checkAccessibilityForDrawing() -> Bool {
    return AXIsProcessTrusted()
}

/// Path of the running executable; Accessibility is granted per path (`swift run` vs `.app` are separate).
func accessibilityExecutablePathForHelp() -> String {
    Bundle.main.executableURL?.path ?? ProcessInfo.processInfo.arguments[0]
}

/// Registers this executable with Accessibility so System Settings can enable the right row (may show a short system prompt).
func promptSystemAccessibilityRegistration() {
    let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    let options = [promptKey: true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(options)
}

struct DrawSettings {
    var threshold: Int = 100
    var detailWidth: Int = 420
    var alphaThreshold: Int = 100
    var edgeMode: Bool = true
    var bleed: Int = 0
    var speed: Int = 2400
    var maxStrokes: Int = 400
    var pointStride: Int = 2
    var minComponent: Int = 8
    var countdown: Int = 5
}

func settingsFromDict(_ d: [String: Any]) -> DrawSettings {
    DrawSettings(
        threshold: d["threshold"] as? Int ?? 100,
        detailWidth: d["detail_width"] as? Int ?? 420,
        alphaThreshold: d["alpha_threshold"] as? Int ?? 100,
        edgeMode: d["edge_mode"] as? Bool ?? true,
        bleed: d["bleed"] as? Int ?? 0,
        speed: d["speed"] as? Int ?? 2400,
        maxStrokes: d["max_strokes"] as? Int ?? 400,
        pointStride: d["point_stride"] as? Int ?? 2,
        minComponent: d["min_component"] as? Int ?? 8,
        countdown: d["countdown"] as? Int ?? 5
    )
}

var escapePressed = false

func processAndDraw(imagePath: String, topLeft: (Int, Int), bottomRight: (Int, Int),
                     settings: DrawSettings, onProgress: ((String) -> Void)? = nil) throws {
    let rect = normalizeRect(topLeft, bottomRight)
    guard rect.width >= 10 && rect.height >= 10 else { throw NSError(domain: "", code: 1, userInfo: [NSLocalizedDescriptionKey: "Area too small"]) }

    onProgress?("Studying...")

    guard var binary = prepareBinaryImage(path: imagePath, rect: rect,
                                          threshold: settings.threshold,
                                          detailWidth: settings.detailWidth,
                                          alphaThreshold: settings.alphaThreshold) else {
        throw NSError(domain: "", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to process image"])
    }

    if settings.edgeMode { binary = toEdgeMask(binary, edgeWidth: 3) }
    if settings.bleed > 0 { binary = applyBleed(binary, bleed: settings.bleed) }

    // Check ink density
    let inkCount = binary.data.filter { $0 == 0 }.count
    if inkCount > 90000 {
        let scale = sqrt(90000.0 / Double(inkCount))
        let rw = max(1, Int(Double(binary.width) * scale))
        let rh = max(1, Int(Double(binary.height) * scale))
        var resized = [UInt8](repeating: 255, count: rw * rh)
        for y in 0..<rh { for x in 0..<rw {
            resized[y*rw+x] = binary.data[Int(Double(y)*Double(binary.height)/Double(rh))*binary.width + Int(Double(x)*Double(binary.width)/Double(rw))]
        }}
        binary = BinaryImage(data: resized, width: rw, height: rh)
    }

    var polylines = extractPolylines(binary, minComponentSize: settings.minComponent, pointStride: settings.pointStride)
    guard !polylines.isEmpty else { throw NSError(domain: "", code: 3, userInfo: [NSLocalizedDescriptionKey: "No drawable paths"]) }

    if settings.maxStrokes > 0 && polylines.count > settings.maxStrokes {
        polylines = Array(polylines.prefix(settings.maxStrokes))
    }

    // Calculate speed for 30-90 second window
    let uniformScale = min(Double(rect.width) / Double(binary.width), Double(rect.height) / Double(binary.height))
    var totalDist = 0.0
    var totalSegs = 0
    for path in polylines {
        for i in 1..<path.count {
            let dx = Double(path[i].0 - path[i-1].0) * uniformScale
            let dy = Double(path[i].1 - path[i-1].1) * uniformScale
            totalDist += sqrt(dx*dx + dy*dy); totalSegs += 1
        }
    }
    let overhead = Double(polylines.count) * 0.045 + Double(totalSegs) * 0.001 * 0.3
    let minAvail = max(1, 30.0 - overhead)
    let maxAvail = max(1, 90.0 - overhead)
    var speed = Double(settings.speed)
    if totalDist > 0 {
        let maxSpeed = totalDist / minAvail
        let minSpeed = totalDist / maxAvail
        speed = max(minSpeed, min(maxSpeed, speed))
    }

    // Countdown
    for i in stride(from: settings.countdown, through: 1, by: -1) {
        onProgress?("Drawing in \(i)s")
        Thread.sleep(forTimeInterval: 1.0)
    }

    onProgress?("Drawing...")
    try drawPolylines(rect: rect, binaryWidth: binary.width, binaryHeight: binary.height,
                      polylines: polylines, speed: speed, onProgress: onProgress)
    onProgress?("Done!")
}

// Returns true to resume, false to cancel
var onPauseHandler: (() -> Bool)?

func drawPolylines(rect: DrawRect, binaryWidth: Int, binaryHeight: Int,
                   polylines: [Polyline], speed: Double, onProgress: ((String) -> Void)?) throws {
    let fitScale = min(Double(rect.width) / Double(max(1, binaryWidth-1)),
                       Double(rect.height) / Double(max(1, binaryHeight-1)))
    let fillScale = max(Double(rect.width) / Double(max(1, binaryWidth-1)),
                        Double(rect.height) / Double(max(1, binaryHeight-1)))
    let uniformScale = fillScale <= fitScale * 1.05 ? fillScale : fitScale
    let drawnW = Double(max(1, binaryWidth-1)) * uniformScale
    let drawnH = Double(max(1, binaryHeight-1)) * uniformScale
    let offsetX = Double(rect.left) + (Double(rect.width) - drawnW) / 2
    let offsetY = Double(rect.top) + (Double(rect.height) - drawnH) / 2
    let safeSpeed = max(100.0, speed)

    MouseControl.mouseUp()
    usleep(30000)

    for (idx, path) in polylines.enumerated() {
        if escapePressed {
            MouseControl.mouseUp()
            escapePressed = false
            if let handler = onPauseHandler {
                let shouldResume = handler() // blocks until user decides
                if !shouldResume { throw DrawCancelled() }
                continue // resume drawing
            }
            throw DrawCancelled()
        }
        guard !path.isEmpty else { continue }

        let x0 = offsetX + Double(path[0].0) * uniformScale
        let y0 = offsetY + Double(path[0].1) * uniformScale

        MouseControl.mouseUp(); usleep(30000)
        MouseControl.moveTo(x0, y0); usleep(15000)
        MouseControl.mouseDown(); usleep(15000)

        var prevX = x0, prevY = y0
        for pi in 1..<path.count {
            if pi % 10 == 0 && escapePressed {
                MouseControl.mouseUp()
                escapePressed = false
                if let handler = onPauseHandler {
                    let shouldResume = handler()
                    if !shouldResume { throw DrawCancelled() }
                    // Resume — countdown
                    onProgress?("Resuming in 3s")
                    Thread.sleep(forTimeInterval: 1)
                    onProgress?("Resuming in 2s")
                    Thread.sleep(forTimeInterval: 1)
                    onProgress?("Resuming in 1s")
                    Thread.sleep(forTimeInterval: 1)
                    onProgress?("Drawing...")
                    // Re-press mouse down to continue
                    MouseControl.moveTo(prevX, prevY)
                    usleep(15000)
                    MouseControl.mouseDown()
                    usleep(15000)
                    continue
                }
                throw DrawCancelled()
            }
            let tx = offsetX + Double(path[pi].0) * uniformScale
            let ty = offsetY + Double(path[pi].1) * uniformScale
            let seg = sqrt((tx-prevX)*(tx-prevX) + (ty-prevY)*(ty-prevY))
            let durMs = max(2.0, (seg / safeSpeed) * 1000.0)
            MouseControl.smoothMoveTo(tx, ty, durationMs: durMs)
            usleep(UInt32(max(500, durMs * 300)))
            prevX = tx; prevY = ty
        }

        MouseControl.mouseUp(); usleep(30000)

        if (idx + 1) % 5 == 0 {
            let pct = Int(100 * Double(idx + 1) / Double(polylines.count))
            onProgress?("Drawing \(pct)%")
        }
    }
    MouseControl.mouseUp()
}
