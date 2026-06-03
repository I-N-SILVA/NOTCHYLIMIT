import Foundation
import Network

/// A tiny loopback-only HTTP server that exposes Notchy's current usage as JSON,
/// so other tools — and AI agents — can read it without screen-scraping.
///
/// `GET http://127.0.0.1:9876/usage` → the latest snapshot for every provider.
/// Binds to `127.0.0.1` only (never a routable interface), serves a single
/// cached payload, and closes each connection immediately. There's no auth
/// because it's unreachable from off-machine; treat it as read-only and local.
public final class LocalAPIServer {
    public static let shared = LocalAPIServer()
    private init() {}

    public static let defaultPort: UInt16 = 9876

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.notchylimit.localapi")
    private let lock = NSLock()
    private var payload = Data("{}".utf8)

    public var isRunning: Bool { listener != nil }

    // MARK: - Lifecycle

    public func start(port: UInt16 = defaultPort) {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        // Loopback-only: bind explicitly to 127.0.0.1 so the port is never
        // exposed on the local network.
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        params.allowLocalEndpointReuse = true

        guard let listener = try? NWListener(using: params) else { return }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.stop() }
        }
        listener.start(queue: queue)
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    /// Replace the cached JSON body served to the next request.
    public func update(_ json: Data) {
        lock.lock(); payload = json; lock.unlock()
    }

    // MARK: - Connection handling

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        // Read (and ignore) the request line, then reply. We don't route on the
        // path — every request gets the usage JSON.
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] _, _, _, _ in
            guard let self else { conn.cancel(); return }
            self.lock.lock(); let body = self.payload; self.lock.unlock()
            let header = """
            HTTP/1.1 200 OK\r
            Content-Type: application/json\r
            Access-Control-Allow-Origin: *\r
            Content-Length: \(body.count)\r
            Connection: close\r
            \r

            """
            var response = Data(header.utf8)
            response.append(body)
            conn.send(content: response, completion: .contentProcessed { _ in conn.cancel() })
        }
    }
}

// MARK: - Export model

/// JSON shape served at `/usage`. Stable, machine-readable, agent-friendly.
struct UsageExport: Encodable {
    let updatedAt: String
    let providers: [String: ProviderExport]

    enum CodingKeys: String, CodingKey {
        case updatedAt = "updated_at"
        case providers
    }
}

struct ProviderExport: Encodable {
    let name: String
    let kind: String          // "percent" | "balance" | "connected"
    let label: String         // "61%", "$10.00", "Active"
    let session: Double?      // 0...1 primary window (percent providers)
    let weekly: Double?       // 0...1 secondary window
    let amount: Double?       // numeric balance (balance providers)
    let resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case name, kind, label, session, weekly, amount
        case resetsAt = "resets_at"
    }

    init(snapshot: ServiceUsageSnapshot) {
        self.name = snapshot.providerId.displayName
        self.label = snapshot.shortLabel
        let iso = ISO8601DateFormatter()
        if snapshot.isStatusOnly {
            kind = "connected"; session = nil; weekly = nil; amount = nil
        } else if snapshot.isBalance {
            kind = "balance"; session = nil; weekly = nil
            amount = snapshot.primaryWindow.usedAmount
        } else {
            kind = "percent"
            session = snapshot.primaryWindow.percentUsed
            weekly = snapshot.secondaryWindow?.percentUsed
            amount = nil
        }
        resetsAt = snapshot.primaryWindow.resetAt.map { iso.string(from: $0) }
    }
}

enum UsageExporter {
    static func json(from snapshots: [ProviderId: ServiceUsageSnapshot]) -> Data {
        var providers: [String: ProviderExport] = [:]
        for (id, snap) in snapshots { providers[id.rawValue] = ProviderExport(snapshot: snap) }
        let export = UsageExport(updatedAt: ISO8601DateFormatter().string(from: Date()), providers: providers)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(export)) ?? Data("{}".utf8)
    }
}
