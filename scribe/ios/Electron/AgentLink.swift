import CryptoKit
import Foundation
import Security
import SwiftUI

// The Agent on the iPad and iPhone: requests go to Electron on the Mac over
// Tailscale, which runs Claude Code, Antigravity or Fairy on the vault and
// streams the steps back (desktop/src/main/phone-link.ts). Built like
// Fairy's iPhone link: the pairing code carries the Mac's certificate
// fingerprint, so this device trusts that one certificate and nothing else.

/// What this device keeps from pairing. It stays on the device and out of backups.
struct AgentPairing: Codable, Equatable {
    var host: String
    var port: Int
    var pin: String
    var key: String
}

enum AgentLinkError: LocalizedError {
    case badCode, notPaired, removed, server(String), keychain(OSStatus)
    var errorDescription: String? {
        switch self {
        case .badCode: "That isn’t a pairing code from Electron. In Settings → iPad & iPhone on the Mac, show a new one."
        case .notPaired: "Pair with your Mac first."
        case .removed: "Your Mac no longer knows this device. Pair again."
        case .server(let message): message
        case .keychain(let status): "This device couldn’t reach its Keychain (\(status))."
        }
    }
}

private enum AgentKeychain {
    static let service = "app.scribe.electron.agent-link"
    static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "pairing"]
    }
    static func save(_ pairing: AgentPairing) throws {
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = try JSONEncoder().encode(pairing)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw AgentLinkError.keychain(status) }
    }
    static func load() -> AgentPairing? {
        var search = query, result: CFTypeRef?
        search[kSecReturnData as String] = true
        guard SecItemCopyMatching(search as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(AgentPairing.self, from: data)
    }
    static func forget() { SecItemDelete(query as CFDictionary) }
}

/// Trusts one certificate, by its SHA-256 fingerprint, with that certificate as the only anchor.
private final class PinnedTrust: NSObject, URLSessionTaskDelegate, Sendable {
    let fingerprint: String
    init(fingerprint: String) { self.fingerprint = fingerprint.lowercased() }

    private func decide(_ challenge: URLAuthenticationChallenge) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let certificate = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first
        else { return (.cancelAuthenticationChallenge, nil) }
        let found = SHA256.hash(data: SecCertificateCopyData(certificate) as Data).map { String(format: "%02x", $0) }.joined()
        guard found == fingerprint else { return (.cancelAuthenticationChallenge, nil) }
        SecTrustSetAnchorCertificates(trust, [certificate] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        return SecTrustEvaluateWithError(trust, nil) ? (.useCredential, URLCredential(trust: trust)) : (.cancelAuthenticationChallenge, nil)
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) { decide(challenge) }
    // Streaming requests ask here instead.
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) { decide(challenge) }
}

/// One thing the Mac's agent reported (the desktop's AgentEvent).
struct AgentEvent: Decodable {
    var kind: String
    var id: String?
    var delta: String?
    var replace: Bool?
    var name: String?
    var summary: String?
    var state: String?
    var detail: String?
    var writes: Bool?
    var title: String?
    var closed: Bool?
    var sessionId: String?
    var costUsd: Double?
    var error: String?
    var denied: [String]?
    var message: String?
}

struct AgentStep: Identifiable, Equatable {
    var id: String
    var name: String
    var summary: String
    var state: String
    var detail: String?
    var writes: Bool
}

enum AgentPart: Equatable {
    case text(String)
    case step(AgentStep)
}

struct AgentTurn: Identifiable, Equatable {
    enum Role { case user, agent }
    let id = UUID()
    var role: Role
    var agent: String
    var text = ""
    var notePath: String?
    var parts: [AgentPart] = []
    var running = false
    var error: String?
    var costUsd: Double?
    var denied: [String]?
    var waiting: [(id: String, title: String)] = []

    static func == (a: AgentTurn, b: AgentTurn) -> Bool {
        a.id == b.id && a.parts == b.parts && a.running == b.running && a.error == b.error && a.waiting.map(\.id) == b.waiting.map(\.id)
    }
}

/// What Electron on the Mac says about itself.
struct AgentAbout: Decodable {
    var name: String
    var vault: String
    var agents: [String: Bool]
    var defaultAgent: String
    var allowEdits: Bool
}

@MainActor
@Observable
final class AgentLink {
    /// One for the app: the Agent sheet shows it, and a pairing link opened from the camera reaches it.
    static let shared = AgentLink()

    static let agents: [(id: String, name: String)] = [("claude", "Claude Code"), ("antigravity", "Antigravity"), ("fairy", "Fairy")]
    static func name(of agent: String) -> String { agents.first { $0.id == agent }?.name ?? agent }

    private(set) var pairing: AgentPairing? = AgentKeychain.load()
    private(set) var about: AgentAbout?
    /// Why the Mac can't be reached, or nil when it can.
    private(set) var problem: String?
    var agent = UserDefaults.standard.string(forKey: "agentChoice") ?? "claude" {
        didSet { UserDefaults.standard.set(agent, forKey: "agentChoice") }
    }
    private(set) var turns: [AgentTurn] = []
    private(set) var runId: String?
    private var sessionId: String?
    private var sessionAgent: String?
    private var following: Task<Void, Never>?
    private var cached: (pin: String, session: URLSession)?

    var busy: Bool { runId != nil }
    /// The Agent sheet is up.
    var showing = false
    /// A pairing link that opened the app, for the pairing screen to use.
    var pendingPair: URL?

    /// An `onyx://pair` link opened from the camera or elsewhere: show the Agent and pair with it.
    func handle(_ url: URL) -> Bool {
        guard url.scheme == "onyx", url.host == "pair" else { return false }
        if pairing == nil { pendingPair = url }
        showing = true
        return true
    }

    // MARK: - Requests

    private func session(_ pairing: AgentPairing) -> URLSession {
        if let cached, cached.pin == pairing.pin { return cached.session }
        cached?.session.invalidateAndCancel()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration, delegate: PinnedTrust(fingerprint: pairing.pin), delegateQueue: nil)
        cached = (pairing.pin, session)
        return session
    }

    private func request(_ pairing: AgentPairing, _ path: String, body: [String: Any]? = nil) throws -> URLRequest {
        guard let url = URL(string: "https://\(pairing.host):\(pairing.port)\(path)") else { throw AgentLinkError.badCode }
        var request = URLRequest(url: url)
        if !pairing.key.isEmpty { request.setValue("Bearer \(pairing.key)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    private func send<T: Decodable>(_ request: URLRequest, using pairing: AgentPairing) async throws -> T {
        let (data, response) = try await session(pairing).data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 {
            forgetHere()
            throw AgentLinkError.removed
        }
        guard status == 200 else {
            let message = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
            throw AgentLinkError.server(message ?? "Your Mac answered \(status).")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// A network failure, in words: usually Tailscale or the Mac being away.
    private func describe(_ error: Error) -> String {
        if let error = error as? AgentLinkError { return error.localizedDescription }
        if let error = error as? URLError {
            switch error.code {
            case .cannotFindHost, .cannotConnectToHost, .timedOut, .networkConnectionLost, .notConnectedToInternet, .dnsLookupFailed:
                return "Can’t reach your Mac. Check that Tailscale is on here and on the Mac, and that Electron is open there."
            case .cancelled, .serverCertificateUntrusted, .secureConnectionFailed:
                return "Your Mac’s certificate has changed. Pair again from Settings → iPad & iPhone on the Mac."
            default: break
            }
        }
        return error.localizedDescription
    }

    // MARK: - Pairing

    /// The code from the Mac: onyx://pair?host=…&port=…&code=…&pin=…
    func pair(with link: URL) async throws {
        let items = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        // Only a Tailscale name gets past iOS's rules for a certificate of the Mac's own.
        guard link.scheme == "onyx", link.host == "pair", let host = value("host"), host.hasSuffix(".ts.net"),
              let port = value("port").flatMap(Int.init), let code = value("code"), let pin = value("pin"), pin.count == 64
        else { throw AgentLinkError.badCode }
        let draft = AgentPairing(host: host, port: port, pin: pin, key: "")
        struct Reply: Decodable { var key: String }
        let reply: Reply = try await send(try request(draft, "/v1/pair", body: ["code": code, "name": UIDevice.current.name]), using: draft)
        let done = AgentPairing(host: host, port: port, pin: pin, key: reply.key)
        try AgentKeychain.save(done)
        pairing = done
        problem = nil
        await refresh()
    }

    func forget() async {
        if let pairing, let ask = try? request(pairing, "/v1/leave", body: [:]) {
            _ = try? await session(pairing).data(for: ask)
        }
        forgetHere()
    }

    private func forgetHere() {
        AgentKeychain.forget()
        pairing = nil
        about = nil
        stopFollowing()
    }

    /// What the Mac offers: which agents are there, and the vault.
    func refresh() async {
        guard let pairing else { return }
        do {
            let about: AgentAbout = try await send(try request(pairing, "/v1/about"), using: pairing)
            self.about = about
            problem = nil
            if about.agents[agent] != true, let first = Self.agents.first(where: { about.agents[$0.id] == true }) {
                agent = about.agents[about.defaultAgent] == true ? about.defaultAgent : first.id
            }
        } catch {
            problem = describe(error)
        }
    }

    // MARK: - Turns

    func pick(_ id: String) {
        guard id != agent, !busy else { return }
        // A conversation belongs to one agent; the other starts afresh.
        if !turns.isEmpty { reset() }
        agent = id
    }

    func reset() {
        stop()
        stopFollowing()
        turns = []
        sessionId = nil
        sessionAgent = nil
        runId = nil
    }

    func send(_ prompt: String, notePath: String?) {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pairing, !text.isEmpty, !busy else { return }
        turns.append(AgentTurn(role: .user, agent: agent, text: text, notePath: notePath))
        turns.append(AgentTurn(role: .agent, agent: agent, running: true))
        let index = turns.count - 1
        var body: [String: Any] = ["agent": agent, "prompt": text]
        if sessionAgent == agent, let sessionId { body["sessionId"] = sessionId }
        if let notePath { body["notePath"] = notePath }
        runId = "starting"
        following = Task {
            do {
                struct Started: Decodable { var run: String }
                let started: Started = try await send(try request(pairing, "/v1/agent/run", body: body), using: pairing)
                runId = started.run
                await follow(started.run, turn: index, pairing: pairing)
            } catch {
                finish(index, error: describe(error))
            }
        }
    }

    func stop() {
        guard let pairing, let runId, runId != "starting", let ask = try? request(pairing, "/v1/agent/stop", body: ["run": runId]) else { return }
        Task { _ = try? await session(pairing).data(for: ask) }
    }

    private func stopFollowing() {
        following?.cancel()
        following = nil
    }

    /// Reads the run's steps as they come, picking up where it left off if the connection drops.
    private func follow(_ run: String, turn: Int, pairing: AgentPairing) async {
        var seen = 0, failures = 0
        while !Task.isCancelled {
            do {
                var ask = try request(pairing, "/v1/agent/events?run=\(run)&after=\(seen)")
                // A limit on silence, not on the stream: the Mac says something at least every 15 seconds.
                ask.timeoutInterval = 45
                let (bytes, response) = try await session(pairing).bytes(for: ask)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 401 { forgetHere(); finish(turn, error: AgentLinkError.removed.localizedDescription); return }
                if status == 404 { finish(turn, error: "Your Mac no longer has this run."); return }
                guard status == 200 else { throw URLError(.badServerResponse) }
                struct Frame: Decodable { var i: Int; var event: AgentEvent }
                for try await line in bytes.lines where line.hasPrefix("data: ") {
                    let frame = try JSONDecoder().decode(Frame.self, from: Data(line.dropFirst(6).utf8))
                    seen = frame.i
                    failures = 0
                    if apply(frame.event, to: turn) { return }
                }
                throw URLError(.networkConnectionLost)
            } catch {
                if Task.isCancelled { return }
                failures += 1
                if failures >= 4 { finish(turn, error: describe(error)); return }
                try? await Task.sleep(nanoseconds: UInt64(failures) * 1_000_000_000)
            }
        }
    }

    /// Folds one event into the turn; true when the turn is over.
    private func apply(_ event: AgentEvent, to index: Int) -> Bool {
        guard turns.indices.contains(index) else { return true }
        var turn = turns[index]
        defer { turns[index] = turn }
        switch event.kind {
        case "session":
            if let id = event.id { sessionId = id; sessionAgent = turn.agent }
        case "text":
            let delta = event.delta ?? ""
            if event.replace == true {
                turn.parts.removeAll { if case .text = $0 { true } else { false } }
                turn.parts.append(.text(delta))
            } else if case .text(let so) = turn.parts.last {
                turn.parts[turn.parts.count - 1] = .text(so + delta)
            } else {
                turn.parts.append(.text(delta))
            }
        case "tool":
            let step = AgentStep(id: event.id ?? UUID().uuidString, name: event.name ?? "", summary: event.summary ?? "",
                                 state: event.state ?? "done", detail: event.detail, writes: event.writes ?? false)
            if let i = turn.parts.firstIndex(where: { if case .step(let s) = $0 { s.id == step.id } else { false } }) {
                turn.parts[i] = .step(step)
            } else {
                turn.parts.append(.step(step))
            }
        case "approval":
            let id = event.id ?? ""
            turn.waiting.removeAll { $0.id == id }
            if event.closed != true { turn.waiting.append((id, event.title ?? "Fairy needs your OK")) }
        case "done":
            if let id = event.sessionId { sessionId = id; sessionAgent = turn.agent }
            turn.running = false
            turn.waiting = []
            turn.error = event.error
            turn.costUsd = event.costUsd
            turn.denied = event.denied
            runId = nil
            return true
        case "error":
            turn.running = false
            turn.waiting = []
            turn.error = event.message ?? "The agent stopped."
            runId = nil
            return true
        default: break
        }
        return false
    }

    private func finish(_ index: Int, error: String) {
        runId = nil
        guard turns.indices.contains(index) else { return }
        turns[index].running = false
        turns[index].waiting = []
        turns[index].error = error
    }
}
