import Foundation
import UIKit

/// The vault as a graph: notes, tags and links that go nowhere yet, joined
/// the way the desktop joins them (desktop/src/main/vault.ts `graph()`).
struct VaultGraph {
    /// `scribe`: a Scribe page linked from a note or linking to one (its id
    /// is `scribe:<page id>`).
    enum Kind { case note, tag, unresolved, scribe }

    struct Node {
        let id: String
        let title: String
        let kind: Kind
        /// The note's path, for notes.
        let rel: String?
        let tags: [String]
        var degree = 0
    }

    var nodes: [Node] = []
    /// Pairs of node indices.
    var edges: [(Int, Int)] = []
    var adjacency: [[Int]] = []

    /// The whole vault, or the notes within `depth` links of `focus`.
    @MainActor
    static func build(_ store: VaultStore, focus: String? = nil, depth: Int = 1, tags: Bool = true) -> VaultGraph {
        var g = VaultGraph()
        var index: [String: Int] = [:]
        func add(_ id: String, _ node: @autoclosure () -> Node) -> Int {
            if let i = index[id] { return i }
            g.nodes.append(node())
            index[id] = g.nodes.count - 1
            return g.nodes.count - 1
        }
        func scribeNode(_ page: LinkedPage) -> Int {
            add("scribe:" + page.id, Node(id: "scribe:" + page.id, title: page.title, kind: .scribe, rel: nil, tags: []))
        }
        var seen = Set<String>()
        func link(_ a: Int, _ b: Int) {
            guard a != b else { return }
            let key = a < b ? "\(a)-\(b)" : "\(b)-\(a)"
            guard seen.insert(key).inserted else { return }
            g.edges.append((a, b))
        }

        // A local graph keeps the focus and what's within `depth` links of it.
        var keep: Set<String>?
        if let focus {
            var set: Set<String> = [focus]
            var frontier = [focus]
            for _ in 0..<depth {
                var next: [String] = []
                for rel in frontier {
                    let out = (store.notes[rel]?.targets ?? []).compactMap { store.resolve($0, from: rel) }
                    for other in out + store.backlinks(of: rel) where store.notes[other] != nil && set.insert(other).inserted {
                        next.append(other)
                    }
                }
                frontier = next
            }
            keep = set
        }

        let rels = store.notes.keys.filter { keep?.contains($0) ?? true }.sorted()
        for rel in rels {
            let meta = store.notes[rel]!
            _ = add(rel, Node(id: rel, title: meta.name, kind: .note, rel: rel, tags: meta.tags))
        }
        for rel in rels {
            let meta = store.notes[rel]!
            let from = index[rel]!
            for target in meta.targets {
                if let scribe = ScribeLink(target: target) {
                    // A link to a Scribe page; one that's gone is left out.
                    if let page = store.scribePages[scribe.pageId] { link(from, scribeNode(page)) }
                    continue
                }
                if let hit = store.resolve(target, from: rel) {
                    if let to = index[hit] { link(from, to) }
                } else if keep == nil {
                    let name = NoteParse.noteName(target).trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty else { continue }
                    let to = add("unresolved:" + name.lowercased(), Node(id: "unresolved:" + name.lowercased(), title: name, kind: .unresolved, rel: nil, tags: []))
                    link(from, to)
                }
            }
            if tags {
                for tag in meta.tags {
                    let to = add("tag:" + tag, Node(id: "tag:" + tag, title: "#" + tag, kind: .tag, rel: nil, tags: [tag]))
                    link(from, to)
                }
            }
        }
        // Pages with [[a note]] typed on them, joined to the notes shown.
        for page in store.scribePages.values.sorted(by: { $0.id < $1.id }) {
            for target in page.links where ScribeLink(target: target) == nil {
                if let hit = store.resolve(target, from: nil), let to = index[hit] { link(scribeNode(page), to) }
            }
        }
        g.adjacency = Array(repeating: [], count: g.nodes.count)
        for (a, b) in g.edges {
            g.nodes[a].degree += 1
            g.nodes[b].degree += 1
            g.adjacency[a].append(b)
            g.adjacency[b].append(a)
        }
        return g
    }

    /// The tag that colours a node: its alphabetically first.
    func primaryTag(_ i: Int) -> String? {
        let node = nodes[i]
        if node.kind == .tag { return node.tags.first }
        return node.tags.min { $0.localizedCompare($1) == .orderedAscending }
    }
}

/// Tag colours, matching desktop/src/renderer/src/graph/tag-colors.ts so a
/// tag is the same pastel on both.
enum TagColors {
    static func family(_ tag: String) -> String {
        (tag.split(separator: "/", maxSplits: 1).first.map(String.init) ?? tag).lowercased()
    }

    /// FNV-1a over UTF-16 code units, as JavaScript's charCodeAt sees them.
    private static func hash(_ s: String) -> UInt32 {
        var h: UInt32 = 0x811C_9DC5
        for unit in s.utf16 {
            h ^= UInt32(unit)
            h = h &* 0x0100_0193
        }
        return h
    }

    static func color(_ tag: String) -> UIColor {
        let fam = family(tag)
        let hue = (Double(hash(fam)) * 137.508).truncatingRemainder(dividingBy: 360)
        let jitter = Int(hash(fam + "~") % 100)
        let sat = Double(62 + jitter % 14) / 100
        let light = Double(76 + jitter % 6) / 100
        // HSL → RGB, as hslToHex does.
        let c = (1 - abs(2 * light - 1)) * sat
        let x = c * (1 - abs((hue / 60).truncatingRemainder(dividingBy: 2) - 1))
        let m = light - c / 2
        let (r, g, b): (Double, Double, Double) = switch hue {
        case ..<60: (c, x, 0)
        case ..<120: (x, c, 0)
        case ..<180: (0, c, x)
        case ..<240: (0, x, c)
        case ..<300: (x, 0, c)
        default: (c, 0, x)
        }
        return UIColor(red: r + m, green: g + m, blue: b + m, alpha: 1)
    }
}

/// The desktop's force layout (graph/physics.worker.ts), d3-force style: a
/// Barnes-Hut charge, link springs, a pull to the centre, tag families
/// gathered into continents, and a round "globe" edge. Runs off the main
/// thread; `positions()` hands back a snapshot.
final class GraphSim: @unchecked Sendable {
    struct Params {
        var centerForce: Float = 0.98
        var repelForce: Float = 20
        var linkForce: Float = 0.63
        var linkDistance: Float = 500
        var continentForce: Float = 0.73
        var globe = true
    }

    private let lock = NSLock()
    private var n = 0
    private var x: [Float] = [], y: [Float] = [], vx: [Float] = [], vy: [Float] = []
    private var fixed: [Bool] = []
    private var src: [Int] = [], dst: [Int] = []
    private var bias: [Float] = [], strength: [Float] = []
    private var group: [Int] = []
    private var groupCount = 0
    private var anchorU: [Float] = [], anchorV: [Float] = []
    private(set) var alpha: Float = 1
    private let params: Params
    private var running = true

    private static let alphaMin: Float = 0.001
    private static let alphaDecay: Float = 1 - pow(0.001, 1 / 300)
    private static let velocityDecay: Float = 0.4
    private static let golden: Float = 2.399963229728653

    init(graph: VaultGraph, groups: [Int], pinned: Int?, params: Params = Params()) {
        self.params = params
        n = graph.nodes.count
        x = Array(repeating: 0, count: n); y = x; vx = x; vy = x
        fixed = Array(repeating: false, count: n)
        group = groups
        groupCount = (groups.max() ?? -1) + 1
        placeAnchors()
        seed()
        var degree = Array(repeating: 0, count: n)
        for (a, b) in graph.edges { src.append(a); dst.append(b); degree[a] += 1; degree[b] += 1 }
        for k in src.indices {
            let ds = Float(degree[src[k]]), dt = Float(degree[dst[k]])
            bias.append(ds / max(ds + dt, 1))
            strength.append(params.linkForce / max(min(ds, dt), 1))
        }
        if let pinned, pinned < n { fixed[pinned] = true; x[pinned] = 0; y[pinned] = 0 }
    }

    func stop() { lock.withLock { running = false } }
    var isRunning: Bool { lock.withLock { running && alpha > Self.alphaMin } }

    /// Runs `count` ticks; false once the layout has cooled.
    @discardableResult
    func step(_ count: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard running else { return false }
        for _ in 0..<count where alpha > Self.alphaMin { tick() }
        return alpha > Self.alphaMin
    }

    func positions() -> ([Float], [Float]) {
        lock.withLock { (x, y) }
    }

    /// Roughly the radius the layout settles at.
    var layoutRadius: Float { params.linkDistance * 0.4 * Float(max(n, 1)).squareRoot() }

    // MARK: Seeding

    private func placeAnchors() {
        anchorU = Array(repeating: 0, count: groupCount)
        anchorV = anchorU
        var size = Array(repeating: 0, count: groupCount)
        for g in group where g >= 0 { size[g] += 1 }
        let order = (0..<groupCount).sorted { size[$0] != size[$1] ? size[$0] > size[$1] : $0 < $1 }
        for (rank, g) in order.enumerated() {
            let r = 0.32 * (Float(rank) / Float(max(groupCount, 1))).squareRoot()
            anchorU[g] = r * cos(Float(rank) * Self.golden)
            anchorV[g] = r * sin(Float(rank) * Self.golden)
        }
    }

    private func seed() {
        let continents = params.continentForce > 0 && groupCount > 0
        let scale = layoutRadius
        var placed = Array(repeating: 0, count: groupCount)
        var loose = 0
        for i in 0..<n {
            let g = group[i]
            let on = continents && g >= 0
            let t: Int
            if on { t = placed[g]; placed[g] += 1 } else { t = loose; loose += 1 }
            let r = params.linkDistance * 0.4 * (Float(t) + 0.5).squareRoot()
            let a = Float(t) * Self.golden
            x[i] = r * cos(a) + (on ? anchorU[g] * scale : 0)
            y[i] = r * sin(a) + (on ? anchorV[g] * scale : 0)
        }
    }

    // MARK: Forces

    private func tick() {
        alpha += (0 - alpha) * Self.alphaDecay
        applyCharge()
        applyLinks()
        applyCenter()
        applyContinents()
        applyGlobe()
        let decay = 1 - Self.velocityDecay
        for i in 0..<n {
            if fixed[i] { vx[i] = 0; vy[i] = 0; continue }
            vx[i] *= decay; vy[i] *= decay
            x[i] += vx[i]; y[i] += vy[i]
        }
    }

    private func applyLinks() {
        let dist = params.linkDistance
        for k in src.indices {
            let s = src[k], t = dst[k]
            var dx = x[t] + vx[t] - x[s] - vx[s]
            var dy = y[t] + vy[t] - y[s] - vy[s]
            var l = (dx * dx + dy * dy).squareRoot()
            if l == 0 { dx = 1e-6; dy = 1e-6; l = 1.4e-6 }
            l = (l - dist) / l * alpha * strength[k]
            dx *= l; dy *= l
            let b = bias[k]
            vx[t] -= dx * b; vy[t] -= dy * b
            vx[s] += dx * (1 - b); vy[s] += dy * (1 - b)
        }
    }

    private func applyCenter() {
        let k = params.centerForce * alpha * 0.02
        for i in 0..<n { vx[i] -= x[i] * k; vy[i] -= y[i] * k }
    }

    private func applyContinents() {
        guard params.continentForce > 0, groupCount > 0 else { return }
        var sx = [Float](repeating: 0, count: groupCount), sy = sx
        var size = [Float](repeating: 0, count: groupCount)
        for i in 0..<n where group[i] >= 0 { sx[group[i]] += x[i]; sy[group[i]] += y[i]; size[group[i]] += 1 }
        let kc = params.continentForce * 0.12 * alpha
        let ka = params.continentForce * 0.006 * alpha
        let scale = layoutRadius
        for i in 0..<n {
            let g = group[i]
            guard g >= 0, !fixed[i] else { continue }
            let cx = sx[g] / size[g], cy = sy[g] / size[g]
            vx[i] += (cx - x[i]) * kc + (anchorU[g] * scale - cx) * ka
            vy[i] += (cy - y[i]) * kc + (anchorV[g] * scale - cy) * ka
        }
    }

    private func applyGlobe() {
        guard params.globe, n >= 3 else { return }
        var mx: Float = 0, my: Float = 0
        for i in 0..<n { mx += x[i]; my += y[i] }
        mx /= Float(n); my /= Float(n)
        var sum2: Float = 0
        for i in 0..<n { let dx = x[i] - mx, dy = y[i] - my; sum2 += dx * dx + dy * dy }
        let edge = 1.3 * (sum2 / Float(n)).squareRoot()
        let k = 0.12 * alpha
        for i in 0..<n where !fixed[i] {
            let dx = x[i] - mx, dy = y[i] - my
            let r = (dx * dx + dy * dy).squareRoot()
            guard r > edge, r > 0 else { continue }
            let pull = (r - edge) / r * k
            vx[i] -= dx * pull; vy[i] -= dy * pull
        }
    }

    // Barnes-Hut: a flat quadtree rebuilt each tick.
    private var qcx: [Float] = [], qcy: [Float] = [], qhalf: [Float] = []
    private var qsx: [Float] = [], qsy: [Float] = [], qmass: [Float] = []
    private var qbody: [Int] = [], qchild: [Int] = []
    private var qcount = 0

    private func qnew(_ cx: Float, _ cy: Float, _ half: Float) -> Int {
        if qcount == qcx.count {
            let grow = max(64, qcx.count)
            qcx += [Float](repeating: 0, count: grow); qcy += [Float](repeating: 0, count: grow)
            qhalf += [Float](repeating: 0, count: grow); qsx += [Float](repeating: 0, count: grow)
            qsy += [Float](repeating: 0, count: grow); qmass += [Float](repeating: 0, count: grow)
            qbody += [Int](repeating: -1, count: grow); qchild += [Int](repeating: -1, count: grow * 4)
        }
        let i = qcount
        qcount += 1
        qcx[i] = cx; qcy[i] = cy; qhalf[i] = half
        qsx[i] = 0; qsy[i] = 0; qmass[i] = 0; qbody[i] = -1
        qchild[i * 4] = -1; qchild[i * 4 + 1] = -1; qchild[i * 4 + 2] = -1; qchild[i * 4 + 3] = -1
        return i
    }

    private func child(_ cell: Int, for b: Int) -> Int {
        let q = (y[b] >= qcy[cell] ? 2 : 0) + (x[b] >= qcx[cell] ? 1 : 0)
        if qchild[cell * 4 + q] >= 0 { return qchild[cell * 4 + q] }
        let h = qhalf[cell] / 2
        let c = qnew(q & 1 != 0 ? qcx[cell] + h : qcx[cell] - h, q & 2 != 0 ? qcy[cell] + h : qcy[cell] - h, h)
        qchild[cell * 4 + q] = c
        return c
    }

    private func insert(_ root: Int, _ b: Int) {
        var cell = root
        for _ in 0..<48 {
            qsx[cell] += x[b]; qsy[cell] += y[b]; qmass[cell] += 1
            if qmass[cell] == 1 { qbody[cell] = b; return }
            if qhalf[cell] < 1e-3 { qbody[cell] = -1; return }
            let existing = qbody[cell]
            if existing >= 0 {
                qbody[cell] = -1
                // Push the resident body one level down before descending.
                let c = child(cell, for: existing)
                qsx[c] += x[existing]; qsy[c] += y[existing]; qmass[c] += 1
                if qmass[c] == 1 { qbody[c] = existing } else { reinsertBelow(c, existing) }
            }
            cell = child(cell, for: b)
        }
    }

    /// A cell that already held a body gets a second: split until they part.
    private func reinsertBelow(_ cell: Int, _ b: Int) {
        let other = qbody[cell]
        guard other >= 0, qhalf[cell] >= 1e-3 else { qbody[cell] = -1; return }
        qbody[cell] = -1
        for body in [other, b] {
            let c = child(cell, for: body)
            qsx[c] += x[body]; qsy[c] += y[body]; qmass[c] += 1
            if qmass[c] == 1 { qbody[c] = body } else { reinsertBelow(c, body) }
        }
    }

    private var stack = [Int](repeating: 0, count: 4096)

    private func applyCharge() {
        guard n > 0 else { return }
        qcount = 0
        var minX = x[0], maxX = x[0], minY = y[0], maxY = y[0]
        for i in 1..<max(n, 1) where i < n {
            minX = min(minX, x[i]); maxX = max(maxX, x[i]); minY = min(minY, y[i]); maxY = max(maxY, y[i])
        }
        let root = qnew((minX + maxX) / 2, (minY + maxY) / 2, max((maxX - minX) / 2, (maxY - minY) / 2, 1) * 1.05)
        for i in 0..<n { insert(root, i) }

        let strength = -params.repelForce * params.linkDistance * params.linkDistance * 0.0033
        let maxD2 = (params.linkDistance * 12) * (params.linkDistance * 12)
        let theta2: Float = 0.81
        for i in 0..<n {
            var sp = 0
            stack[sp] = root; sp += 1
            var fx: Float = 0, fy: Float = 0
            while sp > 0 {
                sp -= 1
                let cell = stack[sp]
                let mass = qmass[cell]
                if mass == 0 { continue }
                let body = qbody[cell]
                if body == i && mass == 1 { continue }
                var dx = qsx[cell] / mass - x[i]
                var dy = qsy[cell] / mass - y[i]
                var d2 = dx * dx + dy * dy
                if d2 == 0 { dx = 1e-6; dy = 1e-6; d2 = 2e-12 }
                let w = qhalf[cell] * 2
                if body >= 0 || w * w / d2 < theta2 {
                    if body == i || d2 > maxD2 { continue }
                    let k = strength * mass * alpha / d2
                    fx += dx * k; fy += dy * k
                } else {
                    for q in 0..<4 {
                        let c = qchild[cell * 4 + q]
                        if c >= 0, sp < stack.count { stack[sp] = c; sp += 1 }
                    }
                }
            }
            vx[i] += fx; vy[i] += fy
        }
    }
}
