import SwiftUI
import VisionKit

// The Agent on the iPad and iPhone (the desktop's AgentView.tsx): ask Claude
// Code, Antigravity or Fairy to work on the vault. The work runs on the Mac,
// in Electron, and the steps come back as they happen (AgentLink.swift).

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
            .background(Color.evBg)
            .toolbarBackground(Color.evChrome, for: .navigationBar)
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
                Image(systemName: "sparkles").font(.system(size: 30)).foregroundStyle(Color(uiColor: EV.accent))
                Text("Pair with your Mac").font(.system(size: 26, weight: .semibold, design: .serif)).foregroundStyle(Color.evText)
                Text("The Agent runs in Electron on your Mac and reaches this device over Tailscale. On the Mac, open Settings → iPad & iPhone, turn it on, and choose Show code.")
                    .foregroundStyle(Color(uiColor: EV.fgDim))
                if DataScannerViewController.isSupported {
                    Button {
                        scanning = true
                    } label: {
                        Label("Scan the code", systemImage: "qrcode.viewfinder").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(busy)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Or paste the pairing link").font(.footnote).foregroundStyle(Color(uiColor: EV.fgSubtle))
                    HStack {
                        TextField("onyx://pair?…", text: $pasted)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textFieldStyle(.roundedBorder)
                        Button("Pair") { pair(pasted) }.disabled(pasted.isEmpty || busy)
                    }
                }
                if busy { ProgressView("Pairing…") }
                if let error { Text(error).foregroundStyle(Color(uiColor: EV.error)) }
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
        Picker("Agent", selection: Binding(get: { link.agent }, set: { link.pick($0) })) {
            ForEach(AgentLink.agents, id: \.id) { agent in
                Text(agent.id == "claude" ? "Claude" : agent.name).tag(agent.id)
            }
        }
        .pickerStyle(.segmented)
        .disabled(link.busy)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.evChrome)
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What should \(AgentLink.name(of: link.agent)) do in your vault?")
                .font(.system(size: 22, weight: .semibold, design: .serif))
                .foregroundStyle(Color.evText)
            Text(explainer).foregroundStyle(Color(uiColor: EV.fgDim))
            if let problem = link.problem {
                Text(problem).foregroundStyle(Color(uiColor: EV.warning))
                Button("Try again") { Task { await link.refresh() } }
            } else if link.about != nil && !available {
                Text(link.agent == "fairy" ? "Fairy isn’t running on your Mac. Open her there, then try again." : "\(AgentLink.name(of: link.agent)) isn’t installed on your Mac.")
                    .foregroundStyle(Color(uiColor: EV.warning))
            }
            ForEach(Self.suggestions, id: \.self) { s in
                Button {
                    submit(s)
                } label: {
                    Text(s).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading).padding(12)
                        .background(Color.evBgAlt, in: RoundedRectangle(cornerRadius: 12))
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
                    Label(((rel as NSString).lastPathComponent as NSString).deletingPathExtension + (withNote ? "" : " (left out)"), systemImage: "doc.text")
                        .font(.footnote)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(withNote ? Color.evBgSel : Color.evBgAlt, in: Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(withNote ? Color.evText : Color(uiColor: EV.fgSubtle))
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Ask \(link.agent == "fairy" ? "Fairy" : "the agent") to find, write or tidy notes…", text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($typing)
                    .padding(10)
                    .background(Color.evBgAlt, in: RoundedRectangle(cornerRadius: 12))
                    .onSubmit { submit(draft) }
                if link.busy {
                    Button("Stop") { link.stop() }.buttonStyle(.bordered)
                } else {
                    Button {
                        submit(draft)
                    } label: {
                        Image(systemName: "arrow.up").font(.system(size: 15, weight: .bold)).frame(width: 34, height: 34)
                    }
                    .buttonStyle(.borderedProminent)
                    .clipShape(Circle())
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || !available)
                }
            }
        }
        .padding(12)
        .background(Color.evChrome)
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
                    .padding(12)
                    .background(Color.evBgSel, in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(Color.evText)
                if let rel = turn.notePath {
                    Text("with \(((rel as NSString).lastPathComponent as NSString).deletingPathExtension) open")
                        .font(.caption).foregroundStyle(Color(uiColor: EV.fgSubtle))
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Circle().fill(dot).frame(width: 8, height: 8)
                    Text(AgentLink.name(of: turn.agent)).font(.footnote.weight(.semibold)).foregroundStyle(Color(uiColor: EV.fgDim))
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
                        .background(Color(uiColor: EV.warning).opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
                }
                if turn.running {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(turn.parts.isEmpty ? "Starting…" : "Working…").font(.footnote).foregroundStyle(Color(uiColor: EV.fgSubtle))
                    }
                }
                if let error = turn.error {
                    Text(error == "Stopped" ? "Stopped." : error)
                        .font(.footnote)
                        .foregroundStyle(error == "Stopped" ? Color(uiColor: EV.fgSubtle) : Color(uiColor: EV.error))
                }
                if !turn.running, !changed.isEmpty || turn.costUsd != nil {
                    HStack(spacing: 10) {
                        if !changed.isEmpty {
                            Text("Changed").foregroundStyle(Color(uiColor: EV.fgSubtle))
                            ForEach(changed, id: \.self) { rel in
                                Button((rel as NSString).deletingPathExtension) { open(rel) }
                            }
                        }
                        if let cost = turn.costUsd { Text(String(format: cost < 0.1 ? "$%.3f" : "$%.2f", cost)).foregroundStyle(Color(uiColor: EV.fgSubtle)) }
                    }
                    .font(.footnote)
                }
            }
        }
    }

    private var dot: Color {
        switch turn.agent {
        case "claude": Color(red: 0.85, green: 0.47, blue: 0.34)
        case "fairy": Color(red: 0.91, green: 0.65, blue: 0.85)
        default: Color(uiColor: EV.info)
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
                if step.state == "running" { ProgressView().controlSize(.mini) } else { Text(step.state == "error" ? "✕" : "✓") }
            }
            .frame(width: 14)
            .foregroundStyle(step.state == "error" ? Color(uiColor: EV.error) : Color(uiColor: EV.success))
            Text(Self.verbs[step.name] ?? step.name.replacingOccurrences(of: "_", with: " ")).foregroundStyle(Color(uiColor: EV.fgDim))
            if let note {
                Button((step.summary as NSString).deletingPathExtension) { open(note) }
                    .foregroundStyle(Color(uiColor: step.writes ? EV.accent : EV.link))
            } else if !step.summary.isEmpty {
                Text(step.summary).foregroundStyle(Color(uiColor: EV.fgSubtle)).lineLimit(1)
            }
        }
        .font(.footnote)
    }
}
