import SwiftUI
import UIKit

/// The graph's layout running in the background, with what drawing needs.
@MainActor
@Observable
final class GraphModel {
    let graph: VaultGraph
    let focus: Int?
    private(set) var xs: [Float] = []
    private(set) var ys: [Float] = []
    private(set) var settled = false
    /// Per node: an index into `palette`, and the radius in world units.
    let colorIndex: [Int]
    let palette: [Color]
    let radius: [CGFloat]
    private let sim: GraphSim

    init(graph: VaultGraph, focus: String?) {
        self.graph = graph
        let focusIndex = focus.flatMap { f in graph.nodes.firstIndex { $0.rel == f } }
        self.focus = focusIndex

        // Colours: the focused note in accent, then its tag's pastel, then by kind.
        var colors: [UIColor] = [EV.accent, EV.fg, EV.fgDim, EV.fgSubtle, EV.tag]
        var byTag: [String: Int] = [:]
        var families: [String: Int] = [:]
        var groups: [Int] = []
        var index: [Int] = []
        for i in graph.nodes.indices {
            let node = graph.nodes[i]
            let tag = graph.primaryTag(i)
            if let tag {
                let fam = TagColors.family(tag)
                if families[fam] == nil { families[fam] = families.count }
                groups.append(families[fam]!)
            } else {
                groups.append(-1)
            }
            if i == focusIndex { index.append(0); continue }
            if let tag {
                let fam = TagColors.family(tag)
                if byTag[fam] == nil { byTag[fam] = colors.count; colors.append(TagColors.color(tag)) }
                index.append(byTag[fam]!)
                continue
            }
            switch node.kind {
            case .tag: index.append(4)
            case .unresolved: index.append(3)
            case .note: index.append(node.degree > 0 ? 1 : 2)
            }
        }
        colorIndex = index
        palette = colors.map { Color(uiColor: $0) }
        // Obsidian's sizing: all the same until hubs grow with √links.
        radius = graph.nodes.map { 0.1 * max(24, min(6.5 * (Double($0.degree) + 1).squareRoot(), 72)) }

        var params = GraphSim.Params()
        if focus != nil {
            params.continentForce = 0
            params.linkDistance = 250
        }
        sim = GraphSim(graph: graph, groups: focus == nil ? groups : groups.map { _ in -1 }, pinned: focusIndex, params: params)
        (xs, ys) = sim.positions()
        run()
    }

    private func run() {
        let sim = sim
        Task.detached(priority: .userInitiated) { [weak self] in
            // Most of the settling happens before the first frame, so the
            // graph opens nearly in place rather than exploding outwards.
            sim.step(120)
            while !Task.isCancelled {
                let more = sim.step(2)
                let (x, y) = sim.positions()
                guard let self else { return }
                await MainActor.run {
                    self.xs = x
                    self.ys = y
                    if !more { self.settled = true }
                }
                if !more { return }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    func stop() { sim.stop() }

    /// The layout's bounds in world units.
    var bounds: CGRect {
        guard !xs.isEmpty else { return CGRect(x: -1, y: -1, width: 2, height: 2) }
        var minX = xs[0], maxX = xs[0], minY = ys[0], maxY = ys[0]
        for i in xs.indices {
            minX = min(minX, xs[i]); maxX = max(maxX, xs[i]); minY = min(minY, ys[i]); maxY = max(maxY, ys[i])
        }
        return CGRect(x: CGFloat(minX), y: CGFloat(minY), width: CGFloat(max(maxX - minX, 1)), height: CGFloat(max(maxY - minY, 1)))
    }
}

/// The desktop's graph view, natively: the whole vault, or the notes around
/// one. Drag to move, pinch to zoom, tap a dot to see what it is.
struct GraphScreen: View {
    let store: VaultStore
    /// Nil for the whole vault; a note for its local graph.
    let focus: String?
    @Environment(\.dismiss) private var dismiss
    @State private var model: GraphModel?
    @State private var center = CGPoint.zero
    @State private var scale: CGFloat = 0.03
    @State private var autoFit = true
    @State private var selected: Int?
    @State private var panStart: CGPoint?
    @State private var zoomStart: (scale: CGFloat, center: CGPoint)?
    @State private var depth = 1
    @State private var size = CGSize.zero

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                ZStack {
                    Color.evBg
                    if let model {
                        canvas(model, size: geo.size)
                            .gesture(pan.simultaneously(with: zoom(geo.size)))
                            .simultaneousGesture(SpatialTapGesture().onEnded { tap($0.location, model, geo.size) })
                            .onChange(of: model.xs) { _, _ in if autoFit { fit(model, geo.size) } }
                            .onAppear { size = geo.size; fit(model, geo.size) }
                            .onChange(of: geo.size) { _, new in size = new; if autoFit { fit(model, new) } }
                    } else {
                        ProgressView("Laying out the graph…").tint(.evAccent).foregroundStyle(Color.evDim)
                    }
                }
                .overlay(alignment: .bottom) {
                    if let model, let selected { card(model, selected) }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                if focus != nil {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Picker("Depth", selection: $depth) {
                                Text("Direct links").tag(1)
                                Text("2 links away").tag(2)
                                Text("3 links away").tag(3)
                            }
                        } label: {
                            Label("Depth \(depth)", systemImage: "circle.hexagongrid")
                        }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        autoFit = true
                        selected = nil
                        if let model { withAnimation(.easeInOut(duration: 0.3)) { fit(model, size) } }
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                    }
                    .accessibilityLabel("Fit to screen")
                }
            }
            .toolbarBackground(Color.evBgAlt, for: .navigationBar)
        }
        .task(id: depth) { await build() }
        .onDisappear { model?.stop() }
    }

    private var title: String {
        guard focus != nil else { return "Graph · \(store.notes.count) notes" }
        return "Local Graph"
    }

    private func build() async {
        model?.stop()
        selected = nil
        autoFit = true
        // Building the index walk is quick; the layout runs in the background.
        model = GraphModel(graph: VaultGraph.build(store, focus: focus, depth: depth, tags: focus == nil), focus: focus)
    }

    // MARK: Camera

    private func fit(_ model: GraphModel, _ size: CGSize) {
        guard size.width > 0 else { return }
        let b = model.bounds
        center = CGPoint(x: b.midX, y: b.midY)
        // A local graph's names are long; leave room for them at the sides.
        scale = min(size.width / b.width, size.height / b.height) * (local ? 0.62 : 0.88)
    }

    private func screen(_ wx: Float, _ wy: Float, _ size: CGSize) -> CGPoint {
        CGPoint(x: (CGFloat(wx) - center.x) * scale + size.width / 2, y: (CGFloat(wy) - center.y) * scale + size.height / 2)
    }

    private var pan: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { v in
                autoFit = false
                if panStart == nil { panStart = center }
                center = CGPoint(x: panStart!.x - v.translation.width / scale, y: panStart!.y - v.translation.height / scale)
            }
            .onEnded { _ in panStart = nil }
    }

    private func zoom(_ size: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { v in
                autoFit = false
                if zoomStart == nil { zoomStart = (scale, center) }
                let start = zoomStart!
                let next = min(max(start.scale * v.magnification, 0.002), 40)
                // Keep the point under the fingers still.
                let anchor = v.startLocation
                let world = CGPoint(x: (anchor.x - size.width / 2) / start.scale + start.center.x,
                                    y: (anchor.y - size.height / 2) / start.scale + start.center.y)
                center = CGPoint(x: world.x - (anchor.x - size.width / 2) / next, y: world.y - (anchor.y - size.height / 2) / next)
                scale = next
            }
            .onEnded { _ in zoomStart = nil }
    }

    /// A local graph is a handful of notes: bigger dots, every one named.
    private var local: Bool { focus != nil }

    /// Node radius on screen: hubs keep their edge, nothing shrinks to a speck.
    private func boost(_ model: GraphModel) -> CGFloat {
        max(1, (local ? 7 : 3) / (2.4 * scale))
    }

    private func tap(_ point: CGPoint, _ model: GraphModel, _ size: CGSize) {
        let b = boost(model)
        var best: (Int, CGFloat)?
        for i in model.xs.indices {
            let p = screen(model.xs[i], model.ys[i], size)
            let d = hypot(p.x - point.x, p.y - point.y)
            let reach = max(model.radius[i] * scale * b, 14)
            if d <= reach, d < (best?.1 ?? .infinity) { best = (i, d) }
        }
        withAnimation(.easeOut(duration: 0.15)) { selected = best?.0 }
    }

    // MARK: Drawing

    private func canvas(_ model: GraphModel, size: CGSize) -> some View {
        Canvas { ctx, size in
            let graph = model.graph
            let n = min(model.xs.count, graph.nodes.count)
            guard n > 0 else { return }
            let b = boost(model)
            var pts = [CGPoint](repeating: .zero, count: n)
            for i in 0..<n { pts[i] = screen(model.xs[i], model.ys[i], size) }
            let near: Set<Int> = selected.map { Set(graph.adjacency[$0] + [$0]) } ?? []

            // Links.
            var links = Path(), hot = Path()
            for (a, c) in graph.edges where a < n && c < n {
                if selected != nil, near.contains(a) && near.contains(c) && (a == selected || c == selected) {
                    hot.move(to: pts[a]); hot.addLine(to: pts[c])
                } else {
                    links.move(to: pts[a]); links.addLine(to: pts[c])
                }
            }
            ctx.stroke(links, with: .color(Color(uiColor: EV.fgSubtle).opacity(selected == nil ? 0.32 : 0.12)), lineWidth: 0.6)
            ctx.stroke(hot, with: .color(.evAccent.opacity(0.85)), lineWidth: 1.2)

            // Dots, one path per colour.
            let bounds = CGRect(origin: .zero, size: size).insetBy(dx: -20, dy: -20)
            var paths = [Path](repeating: Path(), count: model.palette.count)
            var dim = [Path](repeating: Path(), count: model.palette.count)
            for i in 0..<n where bounds.contains(pts[i]) {
                let r = model.radius[i] * scale * b
                let rect = CGRect(x: pts[i].x - r, y: pts[i].y - r, width: r * 2, height: r * 2)
                if selected == nil || near.contains(i) { paths[model.colorIndex[i]].addEllipse(in: rect) }
                else { dim[model.colorIndex[i]].addEllipse(in: rect) }
            }
            for k in paths.indices {
                ctx.fill(dim[k], with: .color(model.palette[k].opacity(0.25)))
                ctx.fill(paths[k], with: .color(model.palette[k]))
            }
            if let s = selected, s < n {
                let r = model.radius[s] * scale * b + 3
                ctx.stroke(Path(ellipseIn: CGRect(x: pts[s].x - r, y: pts[s].y - r, width: r * 2, height: r * 2)), with: .color(.evAccent), lineWidth: 2)
            }

            // Names fade in as you zoom, as on the desktop; the picked dot is
            // always named, and so are its neighbours unless there's a crowd.
            let fadeIn = local && n <= 120 ? 1 : min(1, max(0, scale * 0.8 / 4.4 - 0.25))
            // A hub's crowd of neighbours stays unnamed, or they smear together.
            let nameNear = near.count <= 21
            var drawn = 0
            for i in 0..<n where bounds.contains(pts[i]) {
                let named = i == selected || (nameNear && near.contains(i))
                let alpha = named ? 1 : fadeIn * (selected == nil ? 0.9 : 0.25)
                guard alpha > 0.02, drawn < 300 else { continue }
                drawn += 1
                let r = model.radius[i] * scale * b
                let text = Text(graph.nodes[i].title)
                    .font(.system(size: named && i == selected ? 13 : 11, weight: i == selected ? .semibold : .regular))
                    .foregroundColor(Color(uiColor: EV.fgDim).opacity(alpha))
                ctx.draw(text, at: CGPoint(x: pts[i].x, y: pts[i].y + r + 8), anchor: .top)
            }
        }
    }

    private func card(_ model: GraphModel, _ i: Int) -> some View {
        let node = model.graph.nodes[i]
        return HStack(spacing: 14) {
            Circle().fill(model.palette[model.colorIndex[i]]).frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 2) {
                Text(node.title).font(.headline).foregroundStyle(Color.evFg).lineLimit(2)
                Text(subtitle(node)).font(.caption).foregroundStyle(Color.evSubtle)
            }
            Spacer(minLength: 8)
            switch node.kind {
            case .note:
                Button("Open") {
                    if let rel = node.rel { store.show(rel) }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            case .tag:
                Button("Notes") {
                    store.tagFilter = node.tags.first
                    dismiss()
                }
                .buttonStyle(.bordered)
            case .unresolved:
                Button("Create") {
                    store.follow(node.title)
                    dismiss()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(16)
        .frame(maxWidth: 520)
        .background(Color.evBgAlt, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.evBorder))
        .shadow(color: .black.opacity(0.4), radius: 18, y: 6)
        .padding(16)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func subtitle(_ node: VaultGraph.Node) -> String {
        let links = node.degree == 1 ? "1 link" : "\(node.degree) links"
        switch node.kind {
        case .note:
            let folder = node.rel.map { ($0 as NSString).deletingLastPathComponent } ?? ""
            return folder.isEmpty ? links : "\(folder) · \(links)"
        case .tag: return "Tag · \(links)"
        case .unresolved: return "Not written yet · \(links)"
        }
    }
}
