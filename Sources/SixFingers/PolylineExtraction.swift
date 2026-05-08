import Foundation

typealias Point = (Int, Int)
typealias Polyline = [Point]

private let neighbors8: [Point] = [
    (-1,-1),(0,-1),(1,-1),(-1,0),(1,0),(-1,1),(0,1),(1,1)
]

func simplifyPolyline(_ points: Polyline, stride: Int) -> Polyline {
    guard points.count > 2 else { return points }
    let s = max(1, stride)
    var simplified: Polyline = [points[0]]

    for idx in 1..<(points.count - 1) {
        if s > 1 && idx % s != 0 { continue }
        let (ax, ay) = simplified.last!
        let (bx, by) = points[idx]
        let (cx, cy) = points[idx + 1]
        if (bx - ax) * (cy - by) == (by - ay) * (cx - bx) { continue }
        simplified.append((bx, by))
    }
    if simplified.last! != points.last! { simplified.append(points.last!) }
    return simplified
}

func mergeAndFilter(_ polylines: inout [Polyline], mergeDist: Int = 0) {
    guard !polylines.isEmpty else { return }

    var md = mergeDist
    if md <= 0 {
        let allPts = polylines.flatMap { $0 }
        if !allPts.isEmpty {
            let xs = allPts.map { $0.0 }, ys = allPts.map { $0.1 }
            let extent = max(xs.max()! - xs.min()!, ys.max()! - ys.min()!, 1)
            md = max(4, extent * 4 / 100)
        } else { md = 6 }
    }
    let distSq = md * md

    var merged = true
    while merged {
        merged = false
        var i = 0
        while i < polylines.count {
            if polylines[i].count < 2 { polylines.remove(at: i); continue }

            var bestJ = -1, bestD = distSq + 1, bestRI = false, bestRJ = false
            let piS = polylines[i].first!, piE = polylines[i].last!

            for j in 0..<polylines.count where j != i {
                let pjS = polylines[j].first!, pjE = polylines[j].last!

                var d = (piE.0-pjS.0)*(piE.0-pjS.0) + (piE.1-pjS.1)*(piE.1-pjS.1)
                if d < bestD { bestD = d; bestJ = j; bestRI = false; bestRJ = false }

                d = (piE.0-pjE.0)*(piE.0-pjE.0) + (piE.1-pjE.1)*(piE.1-pjE.1)
                if d < bestD { bestD = d; bestJ = j; bestRI = false; bestRJ = true }

                d = (piS.0-pjS.0)*(piS.0-pjS.0) + (piS.1-pjS.1)*(piS.1-pjS.1)
                if d < bestD { bestD = d; bestJ = j; bestRI = true; bestRJ = false }

                d = (piS.0-pjE.0)*(piS.0-pjE.0) + (piS.1-pjE.1)*(piS.1-pjE.1)
                if d < bestD { bestD = d; bestJ = j; bestRI = true; bestRJ = true }
            }

            if bestJ >= 0 && bestD <= distSq {
                let pi = bestRI ? polylines[i].reversed() : polylines[i]
                let pj = bestRJ ? polylines[bestJ].reversed() : polylines[bestJ]
                polylines[i] = pi + pj
                polylines.remove(at: bestJ)
                if bestJ < i { i -= 1 }
                merged = true; continue
            }
            i += 1
        }
    }
    polylines = polylines.filter { $0.count >= 5 }
}

func nearestNeighborOrder(_ polylines: [Polyline]) -> [Polyline] {
    guard polylines.count > 1 else { return polylines }
    var remaining = Array(0..<polylines.count)
    var ordered = [remaining.removeFirst()]
    var lastEnd = polylines[ordered[0]].last!

    while !remaining.isEmpty {
        var bestIdx = 0, bestDist = Int.max
        for (i, idx) in remaining.enumerated() {
            let s = polylines[idx].first!
            let d = (s.0-lastEnd.0)*(s.0-lastEnd.0) + (s.1-lastEnd.1)*(s.1-lastEnd.1)
            if d < bestDist { bestDist = d; bestIdx = i }
        }
        let chosen = remaining.remove(at: bestIdx)
        ordered.append(chosen)
        lastEnd = polylines[chosen].last!
    }
    return ordered.map { polylines[$0] }
}

func extractPolylines(_ binary: BinaryImage, minComponentSize: Int = 10, pointStride: Int = 2) -> [Polyline] {
    let w = binary.width, h = binary.height

    var ink = Set<Int>()
    for y in 0..<h { for x in 0..<w { if binary.data[y*w+x] == 0 { ink.insert(y*w+x) } } }
    guard !ink.isEmpty else { return [] }

    var visited = Set<Int>()
    var allComponents: [[Polyline]] = []

    func toKey(_ x: Int, _ y: Int) -> Int { y * w + x }
    func fromKey(_ k: Int) -> Point { (k % w, k / w) }

    for seedKey in ink {
        guard !visited.contains(seedKey) else { continue }

        var queue = [seedKey]; visited.insert(seedKey)
        var component: [Point] = []; var qi = 0

        while qi < queue.count {
            let key = queue[qi]; qi += 1
            let (x, y) = fromKey(key); component.append((x, y))
            for (dx, dy) in neighbors8 {
                let nx = x+dx, ny = y+dy
                guard nx >= 0 && nx < w && ny >= 0 && ny < h else { continue }
                let nk = toKey(nx, ny)
                if ink.contains(nk) && !visited.contains(nk) { visited.insert(nk); queue.append(nk) }
            }
        }
        guard component.count >= minComponentSize else { continue }

        var remaining = Set(component.map { toKey($0.0, $0.1) })
        var compPolylines: [Polyline] = []

        while !remaining.isEmpty {
            let startKey = remaining.first!; remaining.remove(startKey)
            var path: Polyline = [fromKey(startKey)]
            var prev: Point? = nil; var curr = fromKey(startKey)

            while true {
                var candidates: [Point] = []
                for (dx, dy) in neighbors8 {
                    let nx = curr.0+dx, ny = curr.1+dy
                    if remaining.contains(toKey(nx, ny)) { candidates.append((nx, ny)) }
                }
                guard !candidates.isEmpty else { break }

                let next: Point
                if let p = prev, candidates.count > 1 {
                    let filtered = candidates.filter { $0 != p }
                    let pool = filtered.isEmpty ? candidates : filtered
                    let vx = curr.0-p.0, vy = curr.1-p.1
                    next = pool.max(by: {
                        ($0.0-curr.0)*vx + ($0.1-curr.1)*vy < ($1.0-curr.0)*vx + ($1.1-curr.1)*vy
                    })!
                } else { next = candidates[0] }

                remaining.remove(toKey(next.0, next.1))
                path.append(next); prev = curr; curr = next
            }
            let simplified = simplifyPolyline(path, stride: pointStride)
            if !simplified.isEmpty { compPolylines.append(simplified) }
        }
        if !compPolylines.isEmpty { allComponents.append(compPolylines) }
    }

    allComponents.sort { a, b in a.reduce(0) { $0+$1.count } > b.reduce(0) { $0+$1.count } }

    var result: [Polyline] = []
    for var comp in allComponents {
        mergeAndFilter(&comp)
        comp.sort { $0.count > $1.count }
        result.append(contentsOf: nearestNeighborOrder(comp))
    }
    return result
}
