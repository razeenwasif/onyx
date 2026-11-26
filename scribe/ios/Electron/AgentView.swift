import SwiftUI
import VisionKit

// The Agent on iPad and iPhone (the desktop's AgentView.tsx), styled after
// Stratus's `#060608` AgentDrawerView: borderless tonal agent switcher,
// `#0B0B0E` suggestion & step cards, `#111114` composer input, pulsing dot.

struct AgentSheet: View {
    let store: VaultStore
    let link: AgentLink
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if link.pairing == nil {
                    AgentPairView(link: link)
                } else {
                    AgentConversation(store: store, link: link, close: { dismiss() })
                }
            }
            .background(Color.evInspector)
            .toolbarBackground(Color.evSheet, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
        }
        .preferredColorScheme(.dark)
        .task { await link.refresh() }
    }
}

// MARK: - Pairing

private struct AgentPairView: View {
    let link: AgentLink
    @State private var scanning = false
    @State private var pasted = ""
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Image(systemName: "sparkles")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(Color.evAccent)
                Text("Pair with your Mac")
                    .font(.system(size: 24, weight: .semibold))
                    .tracking(-0.4)
                    .foregroundStyle(Color.evFg)
                Text("The Agent runs in Electron on your Mac and reaches this device over Tailscale. On the Mac, open Settings → iPad & iPhone, turn it on, and choose Show code.")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.evDim)
                if DataScannerViewController.isSupported {
                    Button {
                        scanning = true
                    } label: {
                        Label("Scan the code", systemImage: "qrcode.viewfinder")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.evAccent)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(Color.evAccent.opacity(0.16), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(busy)
                }
                VStack(alignment: .leading, spacing: 8) {
                    StratusSectionHeader(title: "Or paste the pairing link")
                    HStack(spacing: 8) {
                        TextField("onyx://pair?…", text: $pasted)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(Color.evFg)
                            .padding(.horizontal, 12)
                            .frame(height: 38)
                            .background(Color.evBgAlt, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        StratusActionPill(title: "Pair", tint: .evAccent, background: .evAccent.opacity(0.16)) {
                            pair(pasted)
                        }
                        .disabled(pasted.isEmpty || busy)
                    }
                }
                if busy { ProgressView("Pairing…").tint(.evAccent) }
                if let error { Text(error).font(.footnote).foregroundStyle(Color.evRose) }
            }
            .padding(24)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Agent")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: link.pendingPair) {
            guard let url = link.pendingPair else { return }
            link.pendingPair = nil
            pair(url.absoluteString)
        }
        .sheet(isPresented: $scanning) {
            CodeScanner { text in
                scanning = false
                pair(text)
            }
            .ignoresSafeArea()
        }
    }

    private func pair(_ text: String) {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { error = AgentLinkError.badCode.localizedDescription; return }
        busy = true
        error = nil
        Task {
            do { try await link.pair(with: url) } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}

/// The camera, looking for the pairing QR code.
private struct CodeScanner: UIViewControllerRepresentable {
    let found: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(found: found) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let found: (String) -> Void
        private var done = false
        init(found: @escaping (String) -> Void) { self.found = found }
        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            for case .barcode(let code) in items {
                guard !done, let text = code.payloadStringValue, text.hasPrefix("onyx://pair") else { continue }
                done = true
                scanner.stopScanning()
                found(text)
            }
        }
    }
}

// MARK: - The conversation

private struct AgentConversation: View {
    let store: VaultStore
    let link: AgentLink
    let close: () -> Void
    @State private var draft = ""
    @State private var withNote = true
    @FocusState private var typing: Bool

    private static let suggestions = [
        "Summarise this note and add the summary at the top",
        "Find notes that should link to this one and add the links",
        "Turn the tasks in this note into a checklist by priority",
        "Which of my notes cover duality? List them with a line each",
    ]

    private var notePath: String? {
        guard withNote, let rel = store.current, VaultNode.kind(of: rel) == .note else { return nil }
        return rel
    }
    private var available: Bool { link.about?.agents[link.agent] == true }

    var body: some View {
        VStack(spacing: 0) {
            picker
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if link.turns.isEmpty { empty }
                        ForEach(link.turns) { turn in
                            TurnView(turn: turn, store: store, open: { rel in
                                store.show(rel)
                                close()
                            })
                            .id(turn.id)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: 720, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: link.turns) { _, turns in
                    if let last = turns.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            composer
        }
        .navigationTitle(link.about.map { "Agent · \($0.vault)" } ?? "Agent")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("New conversation", systemImage: "plus") { link.reset() }.disabled(link.turns.isEmpty)
                    Button("Forget this Mac", systemImage: "xmark.circle", role: .destructive) { Task { await link.forget() } }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
    }

    private var picker: some View {
        HStack(spacing: 4) {
            ForEach(AgentLink.agents, id: \.id) { agent in
                let isSelected = link.agent == agent.id
                Button {
                    guard !link.busy else { return }
                    link.pick(agent.id)
                } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(agentDot(agent.id))
                            .frame(width: 6, height: 6)
                        Text(agent.id == "claude" ? "Claude" : agent.name)
                            .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                            .foregroundStyle(isSelected ? Color.evFg : Color.evDim)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(isSelected ? Color.evBgSel : Color.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(link.busy)
            }
        }
        .padding(3)
        .background(Color.evSurfaceSubtle, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.evInspector)
    }

    private func agentDot(_ id: String) -> Color {
        switch id {
        case "claude": .evCoral
        case "fairy": .evViolet
        default: .evSky
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What should \(AgentLink.name(of: link.agent)) do in your vault?")
                .font(.system(size: 20, weight: .semibold))
                .tracking(-0.3)
                .foregroundStyle(Color.evFg)
            Text(explainer)
                .font(.system(size: 13.5))
                .foregroundStyle(Color.evDim)
            if let problem = link.problem {
                Text(problem).font(.footnote).foregroundStyle(Color.evAmber)
                StratusActionPill(title: "Try again", systemImage: "arrow.clockwise", tint: .evAccent) {
                    Task { await link.refresh() }
                }
            } else if link.about != nil && !available {
                Text(link.agent == "fairy" ? "Fairy isn’t running on your Mac. Open her there, then try again." : "\(AgentLink.name(of: link.agent)) isn’t installed on your Mac.")
                    .font(.footnote)
                    .foregroundStyle(Color.evAmber)
            }
            ForEach(Self.suggestions, id: \.self) { s in
                Button {
                    submit(s)
                } label: {
                    Text(s)
                        .font(.system(size: 13.5))
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color.evSurfaceSubtle, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.evText)
                .disabled(!available)
            }
        }
    }

    private var explainer: String {
        let edits = link.about?.allowEdits == false ? "plans changes to" : "edits"
        let base = "It reads, searches and \(edits) your notes. It runs on your Mac, in Electron, and works there while this screen is closed."
        return link.agent == "fairy" ? base + " Anything past her sandbox waits for your OK in Fairy." : base
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let rel = store.current, VaultNode.kind(of: rel) == .note {
                Button {
                    withNote.toggle()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "doc.text").font(.system(size: 11))
                        Text(((rel as NSString).lastPathComponent as NSString).deletingPathExtension + (withNote ? "" : " (left out)"))
                            .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(withNote ? Color.evBgSel : Color.evSurfaceSubtle, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
                .foregroundStyle(withNote ? Color.evAccent : Color.evSubtle)
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Find, write or tidy notes…", text: $draft, axis: .vertical)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.evFg)
                    .lineLimit(1...6)
                    .focused($typing)
                    .padding(10)
                    .background(Color.evBgAlt, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .onSubmit { submit(draft) }
                if link.busy {
                    StratusActionPill(title: "Stop", tint: .evRose, background: .evRose.opacity(0.14)) {
                        link.stop()
                    }
                } else {
                    Button {
                        submit(draft)
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Color.evBg)
                            .frame(width: 34, height: 34)
                            .background(Color.evAccent, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || !available)
                    .opacity(draft.trimmingCharacters(in: .whitespaces).isEmpty || !available ? 0.35 : 1)
                }
            }
        }
        .padding(12)
        .background(Color.evInspector)
    }

    private func submit(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, available, !link.busy else { return }
        link.send(text, notePath: notePath)
        draft = ""
    }
}

private struct TurnView: View {
    let turn: AgentTurn
    let store: VaultStore
    let open: (String) -> Void

    var body: some View {
        if turn.role == .user {
            VStack(alignment: .trailing, spacing: 4) {
                Text(turn.text)
                    .font(.system(size: 14.5))
                    .padding(12)
                    .background(Color.evBgSel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .foregroundStyle(Color.evFg)
                if let rel = turn.notePath {
                    Text("with \(((rel as NSString).lastPathComponent as NSString).deletingPathExtension) open")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.evSubtle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    StratusStatusDot(color: dot, size: 6, pulse: turn.running)
                    Text(AgentLink.name(of: turn.agent))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.evDim)
                }
                ForEach(Array(turn.parts.enumerated()), id: \.offset) { _, part in
                    switch part {
                    case .text(let text):
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(Markdown.parse(text)) { node in
                                BlockView(block: node.block, line: node.line, store: store, depth: 0)
                            }
                        }
                        .environment(\.openURL, OpenURLAction { url in
                            guard url.scheme == "electron", url.host == "note",
                                  let t = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value,
                                  let rel = store.resolve(t, from: nil) else { return .systemAction }
                            open(rel)
                            return .handled
                        })
                    case .step(let step):
                        StepRow(step: step, note: noteFor(step), open: open)
                    }
                }
                ForEach(turn.waiting, id: \.id) { wait in
                    Text("**Waiting for your OK in Fairy:** \(wait.title)")
                        .font(.footnote)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.evAmber.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                if turn.running {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small).tint(.evAccent)
                        Text(turn.parts.isEmpty ? "Starting…" : "Working…").font(.footnote).foregroundStyle(Color.evSubtle)
                    }
                }
                if let error = turn.error {
                    Text(error == "Stopped" ? "Stopped." : error)
                        .font(.footnote)
                        .foregroundStyle(error == "Stopped" ? Color.evSubtle : Color.evRose)
                }
                if !turn.running, !changed.isEmpty || turn.costUsd != nil {
                    HStack(spacing: 10) {
                        if !changed.isEmpty {
                            Text("Changed").foregroundStyle(Color.evSubtle)
                            ForEach(changed, id: \.self) { rel in
                                Button((rel as NSString).deletingPathExtension) { open(rel) }
                                    .foregroundStyle(Color.evAccent)
                            }
                        }
                        if let cost = turn.costUsd {
                            Text(String(format: cost < 0.1 ? "$%.3f" : "$%.2f", cost))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Color.evSubtle)
                        }
                    }
                    .font(.footnote)
                }
            }
        }
    }

    private var dot: Color {
        switch turn.agent {
        case "claude": .evCoral
        case "fairy": .evViolet
        default: .evSky
        }
    }

    private func noteFor(_ step: AgentStep) -> String? {
        guard !step.summary.isEmpty else { return nil }
        return store.resolve(step.summary, from: nil)
    }

    private var changed: [String] {
        var seen: [String] = []
        for part in turn.parts {
            if case .step(let s) = part, s.writes, s.state == "done", let rel = noteFor(s), !seen.contains(rel) { seen.append(rel) }
        }
        return seen
    }
}

private struct StepRow: View {
    let step: AgentStep
    let note: String?
    let open: (String) -> Void

    private static let verbs: [String: String] = [
        "Read": "Read", "view_file": "Read", "read_file": "Read", "read": "Read",
        "Edit": "Edited", "MultiEdit": "Edited", "edit_file": "Edited", "replace_file_content": "Edited", "multi_replace_file_content": "Edited", "edit": "Edited",
        "Write": "Wrote", "write_to_file": "Wrote", "write": "Wrote", "create_file": "Created",
        "Glob": "Found files", "find_by_name": "Found files", "list_dir": "Listed", "list": "Listed",
        "Grep": "Searched for", "grep_search": "Searched for", "search": "Searched for",
        "WebSearch": "Searched the web for", "search_web": "Searched the web for", "web-search": "Searched the web for",
        "WebFetch": "Read", "read_url_content": "Read", "web-read": "Read", "run": "Ran", "run_command": "Ran",
    ]

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Group {
                if step.state == "running" { ProgressView().controlSize(.mini).tint(.evAccent) } else { Text(step.state == "error" ? "✕" : "✓") }
            }
            .frame(width: 14)
            .foregroundStyle(step.state == "error" ? Color.evRose : Color.evMint)
            Text(Self.verbs[step.name] ?? step.name.replacingOccurrences(of: "_", with: " ")).foregroundStyle(Color.evDim)
            if let note {
                Button((step.summary as NSString).deletingPathExtension) { open(note) }
                    .foregroundStyle(step.writes ? Color.evAccent : Color.evSky)
            } else if !step.summary.isEmpty {
                Text(step.summary)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Color.evSubtle)
                    .lineLimit(1)
            }
        }
        .font(.footnote)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.evSurfaceSubtle, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
