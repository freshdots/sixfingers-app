import AppKit
import Foundation

struct BinaryImage {
    var data: [UInt8]  // 0 = ink, 255 = white
    let width: Int
    let height: Int
}

struct DrawRect {
    let left: Int, top: Int, right: Int, bottom: Int
    var width: Int { max(1, right - left) }
    var height: Int { max(1, bottom - top) }
}

func normalizeRect(_ p1: (Int, Int), _ p2: (Int, Int)) -> DrawRect {
    DrawRect(left: min(p1.0, p2.0), top: min(p1.1, p2.1),
             right: max(p1.0, p2.0), bottom: max(p1.1, p2.1))
}

func prepareBinaryImage(path: String, rect: DrawRect, threshold: Int = 150,
                         detailWidth: Int = 340, alphaThreshold: Int = 8) -> BinaryImage? {
    guard let nsImage = NSImage(contentsOfFile: path),
          let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

    let w = cgImage.width, h = cgImage.height

    // Render to grayscale with white background
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                               bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                               bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
    ctx.setFillColor(gray: 1.0, alpha: 1.0)
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))

    guard let grayData = ctx.data else { return nil }
    let gray = grayData.assumingMemoryBound(to: UInt8.self)

    // Auto-crop whitespace
    var cropL = w, cropT = h, cropR = 0, cropB = 0
    for y in 0..<h {
        for x in 0..<w {
            if gray[y * w + x] < 250 {
                cropL = min(cropL, x); cropT = min(cropT, y)
                cropR = max(cropR, x); cropB = max(cropB, y)
            }
        }
    }

    var srcW = w, srcH = h, offsetX = 0, offsetY = 0
    if cropR > cropL && cropB > cropT {
        let mx = max(2, w / 50), my = max(2, h / 50)
        offsetX = max(0, cropL - mx); offsetY = max(0, cropT - my)
        srcW = min(w, cropR + mx + 1) - offsetX
        srcH = min(h, cropB + my + 1) - offsetY
    }

    // Calculate target size
    var areaScale = min(Double(rect.width) / Double(srcW), Double(rect.height) / Double(srcH))
    areaScale = max(areaScale, 0.01)
    var targetW = max(1, Int(Double(srcW) * areaScale))
    var targetH = max(1, Int(Double(srcH) * areaScale))

    let detailCap = max(20, detailWidth)
    if targetW > detailCap {
        let ds = Double(detailCap) / Double(targetW)
        targetW = max(1, Int(Double(targetW) * ds))
        targetH = max(1, Int(Double(targetH) * ds))
    }

    let t = UInt8(max(0, min(255, threshold)))

    // Threshold and resize (nearest neighbor)
    var result = [UInt8](repeating: 255, count: targetW * targetH)
    for y in 0..<targetH {
        let sy = offsetY + Int(Double(y) * Double(srcH) / Double(targetH))
        for x in 0..<targetW {
            let sx = offsetX + Int(Double(x) * Double(srcW) / Double(targetW))
            result[y * targetW + x] = gray[sy * w + sx] > t ? 255 : 0
        }
    }

    return BinaryImage(data: result, width: targetW, height: targetH)
}

func toEdgeMask(_ binary: BinaryImage, edgeWidth: Int = 3) -> BinaryImage {
    let k = max(1, edgeWidth / 2)
    var result = [UInt8](repeating: 255, count: binary.width * binary.height)

    for y in 0..<binary.height {
        for x in 0..<binary.width {
            guard binary.data[y * binary.width + x] == 0 else { continue }
            var isEdge = false
            for dy in -k...k where !isEdge {
                for dx in -k...k where !isEdge {
                    if dx == 0 && dy == 0 { continue }
                    let nx = x + dx, ny = y + dy
                    if nx < 0 || nx >= binary.width || ny < 0 || ny >= binary.height {
                        isEdge = true
                    } else if binary.data[ny * binary.width + nx] != 0 {
                        isEdge = true
                    }
                }
            }
            if isEdge { result[y * binary.width + x] = 0 }
        }
    }
    return BinaryImage(data: result, width: binary.width, height: binary.height)
}

func applyBleed(_ binary: BinaryImage, bleed: Int) -> BinaryImage {
    guard bleed > 0 else { return binary }
    var current = binary.data
    let w = binary.width, h = binary.height

    for _ in 0..<bleed {
        var next = current
        for y in 0..<h {
            for x in 0..<w {
                guard current[y * w + x] != 0 else { continue }
                for dy in -1...1 {
                    for dx in -1...1 {
                        let nx = x + dx, ny = y + dy
                        if nx >= 0 && nx < w && ny >= 0 && ny < h && current[ny * w + nx] == 0 {
                            next[y * w + x] = 0
                        }
                    }
                }
            }
        }
        current = next
    }
    return BinaryImage(data: current, width: w, height: h)
}

func autoSettingsForImage(path: String, canvasW: Int, canvasH: Int) -> [String: Any] {
    guard let nsImage = NSImage(contentsOfFile: path),
          let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        return defaultDrawSettings()
    }

    let w = cgImage.width, h = cgImage.height
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                               bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                               bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return defaultDrawSettings() }
    ctx.setFillColor(gray: 1.0, alpha: 1.0)
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))

    guard let data = ctx.data else { return defaultDrawSettings() }
    let gray = data.assumingMemoryBound(to: UInt8.self)
    let total = w * h

    var darkCounts: [Int: Int] = [:]
    for t in [80, 100, 120, 140, 160, 180, 200] {
        var count = 0
        for i in 0..<total { if gray[i] < t { count += 1 } }
        darkCounts[t] = count
    }

    var bestThreshold = 100
    for t in [80, 100, 120, 140, 160, 180, 200] {
        if Double(darkCounts[t]!) / Double(total) < 0.30 {
            bestThreshold = t
        } else { break }
    }

    let inkRatio = Double(darkCounts[bestThreshold]!) / Double(total)
    let isLineArt = Double(darkCounts[80]!) / Double(total) < 0.05

    let canvasArea = max(1, canvasW * canvasH)
    var areaRatio = sqrt(Double(canvasArea) / Double(400 * 400))
    areaRatio = max(0.3, min(3.0, areaRatio))
    let complexity = max(0.5, min(2.5, inkRatio / 0.08))
    let maxStrokes = max(200, min(3000, Int(800 * areaRatio * complexity)))
    let detailWidth = max(500, min(1200, Int(500 * max(1.0, areaRatio))))

    return [
        "max_strokes": maxStrokes, "detail_width": detailWidth,
        "threshold": bestThreshold, "alpha_threshold": 100,
        "speed": max(1500, Int(3500 * max(0.5, areaRatio))),
        "point_stride": 2, "min_component": max(3, min(15, Int(8.0 * min(1.0, areaRatio) / complexity))),
        "edge_mode": !isLineArt, "bleed": 0, "countdown": 5,
    ]
}

func defaultDrawSettings() -> [String: Any] {
    ["max_strokes": 400, "detail_width": 420, "threshold": 100, "alpha_threshold": 100,
     "speed": 2400, "point_stride": 2, "min_component": 8, "edge_mode": true, "bleed": 0, "countdown": 5]
}
