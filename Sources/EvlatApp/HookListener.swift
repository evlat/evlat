import Foundation
import Network
import EvlatCore
import EvlatAgents

/// The socket, and nothing above it.
///
/// What a request *means* — the route table, the browser defence, the parsing
/// and the `{}` body — lives in `EvlatCore.LocalAPI` and is tested without a
/// socket. What is left here is transport: accept a connection, accumulate
/// bytes, hand them to `HTTPRequest.parse`, write the answer back.
///
/// It is **not** reached through `Platform`. That type exists so the pure core
/// can ask the app a question and be told "I don't know" when nothing is bound;
/// a listener has no such answer. A no-op listener does not say "I don't know",
/// it silently receives no events — the opposite of this repo's discipline.
/// The call direction here is App → Core.
public final class HookListener {
    /// Where the endpoint stands. A failure to bind is a **value**, not a log
    /// line that scrolls away: the one way this feature breaks in the field is
    /// another Evlat already holding the socket, and then nothing at all
    /// happens — no crash, no event, no symptom. `--list` prints this.
    public enum Status: Equatable {
        case stopped
        /// The sandbox port bound (`Transport.sandboxPort`). The port is the
        /// one actually bound, which is not always the one asked for: `0`
        /// means "any free port" and is what tests use.
        case listening(UInt16)
        case unavailable(UInt16, String)
        /// Bound on a unix socket (`Transport.unix`), at this path.
        case listeningAt(String)
        case unavailableAt(String, String)

        public var text: String {
            switch self {
            case .stopped: return "not started"
            case .listening(let port): return "listening on 127.0.0.1:\(port)"
            case .unavailable(let port, let reason): return "port \(port) unavailable — \(reason)"
            case .listeningAt(let path): return "listening on \(path)"
            case .unavailableAt(let path, let reason): return "\(path) unavailable — \(reason)"
            }
        }
    }

    /// What the listener binds: a unix socket's path (`EvlatSocket`) in a
    /// directory only the user can enter, this Mac's and each machine's —
    /// or the one loopback port left, the Docker sandboxes', whose agents
    /// reach this Mac through the sandbox's proxy and can name no file here
    /// (`SandboxListener`). A port's listener is a sandbox's whatever
    /// `origin` says: anything on this Mac can connect to a port.
    public enum Transport: Equatable {
        case unix(String)
        case sandboxPort(UInt16)
    }

    /// The reason a socket is not taken: another process answers there.
    static let heldByAnother = "another Evlat holds it"

    private let transport: Transport
    private var requestedPort: UInt16 {
        if case .sandboxPort(let port) = transport { return port }
        return 0
    }
    /// The socket file this listener made, once bound: `stop()` removes the
    /// file only while it is still this one — not one another Evlat bound
    /// at the same path after a stale one was cleared.
    private var boundFile: UnixSocket.Identity?
    /// The agents a request's route is looked up in (`LocalAPI.handle`).
    private let agents: [any Agent]
    /// What `LocalAPI` is told about this listener: where what arrives here
    /// comes from — this Mac, one remote machine's tunnel (`RemoteTunnels`)
    /// or a Docker sandbox — and where an Antigravity transcript may be
    /// read. `LocalAPI` decides what that means; the listener only knows
    /// which one it is.
    private let identity: LocalAPI.Listener
    private let onDelivery: (LocalAPI.Delivery) -> Void
    private let onStatus: ((Status) -> Void)?
    /// A held request went away before it was answered: Claude's time ran
    /// out or its turn ended. Main queue.
    private let onAbandoned: ((String) -> Void)?
    /// Permission requests waiting for the user, by request id. Touched on
    /// `queue` only.
    private var held: [String: NWConnection] = [:]
    private let queue = DispatchQueue(label: "dev.kalaomer.evlat.hooks")
    private var listener: NWListener?

    /// Status is written on `queue` (that is where `NWListener` reports) and
    /// read from the main queue, so it is guarded rather than left to chance.
    private let lock = NSLock()
    private var currentStatus: Status = .stopped
    private let settled = DispatchSemaphore(value: 0)
    private var hasSettled = false

    /// An accumulating buffer on a local port is unbounded work handed to us by
    /// whoever connects: a body that never ends would grow it until the process
    /// dies. The largest real body measured is a few KB; a megabyte is far past
    /// anything a hook sends and still cheap to hold.
    private static let maxRequestBytes = 1 << 20

    /// `onDelivery` is called on the **main queue** with an already-parsed hook
    /// event or usage report. The raw body is not carried across: it reaches
    /// 8 KB and nothing on the main queue wants it — a status line's body
    /// least of all (`UsageReport`).
    ///
    /// `onStatus` is called on the main queue every time the endpoint's state
    /// changes. It is taken here rather than left as a settable property
    /// because it is read from the listener's queue: a caller assigning it
    /// after `start()` would be racing the first state report.
    ///
    /// A permission request (`LocalAPI.Delivery.permission`) is delivered
    /// with its connection **held** open; `answer(_:with:)` writes the
    /// user's decision to it, and `onAbandoned` reports one that closed first.
    ///
    /// `origin` is a socket's listener's role (`LocalAPI.Origin.role`):
    /// this Mac's (`.local`), or one machine's channel end (`.machine`). A
    /// sandbox port's is `.sandbox`, the one that believes `X-Evlat-Sandbox`
    /// (`SandboxListener`).
    public init(transport: Transport,
                origin asked: LocalAPI.Origin = .local,
                transcriptRoots: [URL] = [],
                agents: [any Agent] = Agents.all,
                onStatus: ((Status) -> Void)? = nil,
                onAbandoned: ((String) -> Void)? = nil,
                onDelivery: @escaping (LocalAPI.Delivery) -> Void) {
        self.transport = transport
        let origin: LocalAPI.Origin
        if case .sandboxPort = transport { origin = .sandbox } else { origin = asked }
        self.agents = agents
        self.identity = LocalAPI.Listener(origin: origin, transcriptRoots: transcriptRoots,
                                          routes: RouteTable(agents))
        self.onStatus = onStatus
        self.onAbandoned = onAbandoned
        self.onDelivery = onDelivery
    }

    public var status: Status {
        lock.lock(); defer { lock.unlock() }
        return currentStatus
    }

    /// Starts binding. It returns immediately; the result arrives through
    /// `status`, because `NWListener` reports "address already in use" through
    /// its state handler and not from the initialiser.
    public func start() {
        if case .unix(let path) = transport { return startUnix(path) }
        let parameters = NWParameters.tcp
        // Only the loopback interface. The endpoint takes no identity and acts
        // on what it is told, so it must not be reachable from the network the
        // machine is on. `lsof` still prints it as `*:<port>`; that is the
        // socket's address family, not its reachability.
        parameters.requiredInterfaceType = .loopback
        // Rebinding right after a restart otherwise fails while the previous
        // socket sits in TIME_WAIT — `make run` replaces the process in
        // well under that. It is SO_REUSEADDR, not SO_REUSEPORT: a second
        // process still cannot take a port that is already being listened on
        // (pinned by `testASecondListenerCannotTakeTheSamePort`).
        parameters.allowLocalEndpointReuse = true

        guard let port = NWEndpoint.Port(rawValue: requestedPort) else {
            setStatus(.unavailable(requestedPort, "not a port number"))
            return
        }
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: port)
        } catch {
            setStatus(.unavailable(requestedPort, "\(error)"))
            return
        }
        // `listener` is captured **weakly**: `NWListener` owns this handler, so
        // a strong capture is a cycle and the object survives its own `cancel`.
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                // The bound port, not the requested one: `0` resolves here.
                let port = listener?.port?.rawValue ?? self.requestedPort
                self.setStatus(.listening(port))
            case .failed(let error):
                self.setStatus(.unavailable(self.requestedPort, Self.describe(error)))
            // `.waiting` is not terminal — the framework keeps retrying — but it
            // is exactly what a busy port can look like, and a caller waiting
            // for an answer must not sit through its whole timeout for one.
            // It is reported and left running: if the other Evlat quits, the
            // next `.ready` overwrites this.
            case .waiting(let error):
                self.setStatus(.unavailable(self.requestedPort, Self.describe(error)))
            case .cancelled:
                self.setStatus(.stopped)
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.serve(connection)
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    /// Binds a unix socket at `path`, taking a stale file but never a live
    /// one: its directory made the user's alone first (`UnixSocket`), then
    /// whatever is at the path asked — something answers, and it is another
    /// Evlat's; nothing does, and the file is a dead one's to clear.
    private func startUnix(_ path: String) {
        guard UnixSocket.address(path) != nil else {
            setStatus(.unavailableAt(path, "too long for a socket's address"))
            return
        }
        if let refusal = UnixSocket.prepareDirectory((path as NSString).deletingLastPathComponent) {
            setStatus(.unavailableAt(path, refusal.text))
            return
        }
        switch UnixSocket.probe(path) {
        case .absent: break
        case .stale: unlink(path)
        case .live:
            setStatus(.unavailableAt(path, Self.heldByAnother))
            return
        case .unknown(let code):
            setStatus(.unavailableAt(path, String(cString: strerror(code)) + " (\(code))"))
            return
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .unix(path: path)
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            setStatus(.unavailableAt(path, "\(error)"))
            return
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                // Which file is ours, read before anyone is told it is
                // bound: `stop()` compares against it.
                if self.boundFile == nil { self.boundFile = UnixSocket.identity(of: path) }
                self.setStatus(.listeningAt(path))
            case .failed(let error), .waiting(let error):
                self.setStatus(.unavailableAt(path, Self.describe(error)))
            case .cancelled:
                self.setStatus(.stopped)
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.serve(connection)
        }
        self.listener = listener
        listener.start(queue: queue)
    }
    /// Held requests are dropped with it: Claude then has no decision, which
    /// under `--permission-prompts none` is a denial.
    /// Each is reported abandoned, so its card does not wait on a
    /// connection that is gone.
    public func stop() {
        listener?.cancel()
        listener = nil
        // The socket file outlives its listener. Removed only while it is
        // still the one this listener bound: a second Evlat that cleared it
        // as stale and bound its own keeps that one.
        if case .unix(let path) = transport {
            queue.sync {
                if let mine = boundFile, UnixSocket.identity(of: path) == mine { unlink(path) }
                boundFile = nil
            }
        }
        queue.async { [self] in
            let dropped = held
            held.removeAll()
            dropped.values.forEach { $0.cancel() }
            guard let abandoned = onAbandoned, !dropped.isEmpty else { return }
            DispatchQueue.main.async { dropped.keys.forEach(abandoned) }
        }
    }

    /// The sandbox port bound, while it is.
    public var boundPort: UInt16? {
        if case .listening(let port) = status { return port }
        return nil
    }

    /// The socket a turn's permission hook posts to, while a socket's
    /// listener is bound.
    public var boundPath: String? {
        if case .listeningAt(let path) = status { return path }
        return nil
    }

    /// Writes the answer to a held request and closes it. An id no longer
    /// held (abandoned, answered) is ignored. Any queue.
    public func answer(_ id: String, with response: LocalAPI.Response) {
        queue.async { [self] in
            guard let connection = held.removeValue(forKey: id) else { return }
            connection.send(content: Data(response.httpText.utf8),
                            completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    /// Blocks until the endpoint is either bound or known to be unusable.
    ///
    /// For `--list` and for tests, which have to *print* or *assert* the
    /// outcome; the running app never calls it, it reads `status` from the
    /// callback instead. Must not be called from the listener's own queue.
    @discardableResult
    public func awaitSettled(timeout: TimeInterval = 2) -> Status {
        // Signalled back so a second caller is not left waiting on a semaphore
        // that has already been consumed.
        if settled.wait(timeout: .now() + timeout) == .success { settled.signal() }
        return status
    }

    private func setStatus(_ new: Status) {
        lock.lock()
        let changed = currentStatus != new
        currentStatus = new
        let firstAnswer = !hasSettled && new != .stopped
        if firstAnswer { hasSettled = true }
        lock.unlock()
        if firstAnswer { settled.signal() }
        guard changed, let report = onStatus else { return }
        DispatchQueue.main.async { report(new) }
    }

    /// `NWError`'s own description is a long type dump; the POSIX code is the
    /// part that tells "another process has the port" from "the port is not
    /// allowed".
    private static func describe(_ error: NWError) -> String {
        if case .posix(let code) = error {
            return String(cString: strerror(code.rawValue)) + " (\(code.rawValue))"
        }
        return "\(error)"
    }

    // MARK: - One connection

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        var buffer = Data()
        func read() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
                [weak self] data, _, isComplete, error in
                guard let self = self else { connection.cancel(); return }
                if let data = data { buffer.append(data) }
                // The buffer is handed over whole on every pass: a request can
                // arrive in any number of pieces, and `parse` answers `nil`
                // until the announced body is all there. Its indices are the
                // buffer's own, which is what lets this slice keep growing.
                if let request = HTTPRequest.parse(buffer) {
                    self.respond(connection, to: request)
                    return
                }
                if buffer.count > Self.maxRequestBytes || isComplete || error != nil {
                    connection.cancel()
                    return
                }
                read()
            }
        }
        read()
    }

    /// The answer is written from **this** queue and the delivery is handed to
    /// the main queue afterwards.
    ///
    /// The installed command runs `curl -s -m 2` under a hook with `timeout: 5`,
    /// so the agent is waiting on this write. Answering from the main queue
    /// would put the agent behind whatever the UI is doing — v1 kept a
    /// semaphore for that and used it only on its read endpoints, never here.
    private func respond(_ connection: NWConnection, to request: HTTPRequest) {
        let outcome = LocalAPI.handle(request, listener: identity, agents: agents)
        if let response = outcome.response {
            connection.send(content: Data(response.httpText.utf8),
                            completion: .contentProcessed { _ in connection.cancel() })
        } else if let id = Self.heldID(outcome.delivery), onAbandoned != nil {
            hold(connection, id: id)
        } else {
            // Nobody here answers permissions (a capture): refused at once
            // rather than held for ever, and still delivered so a capture
            // can say it saw one. A machine never gets here: `LocalAPI`
            // already answered it `404`.
            connection.send(content: Data(LocalAPI.noSuchEndpoint.httpText.utf8),
                            completion: .contentProcessed { _ in connection.cancel() })
        }
        guard let delivery = outcome.delivery else { return }
        let deliver = onDelivery
        DispatchQueue.main.async { deliver(delivery) }
    }

    /// The request whose answer is the user's: a chat turn's, a terminal
    /// session's (`ApprovalHook`), or a tunnel's `ssh` prompt (`Askpass`).
    private static func heldID(_ delivery: LocalAPI.Delivery?) -> String? {
        switch delivery {
        case .permission(let asked)?: return asked.id
        case .approval(let asked)?: return asked.id
        case .askpass(let asked)?: return asked.id
        default: return nil
        }
    }

    /// Keeps the connection until `answer`, and watches it: a far side that
    /// closes (end of stream, an error) abandons the request. The client
    /// sends nothing more after its request, so any read that completes
    /// is the close.
    private func hold(_ connection: NWConnection, id: String) {
        held[id] = connection
        let abandoned = onAbandoned
        func watch() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] data, _, isComplete, error in
                // Nobody left to answer it: closed, like `serve` does.
                guard let self else { connection.cancel(); return }
                guard self.held[id] === connection else { return }
                if isComplete || error != nil {
                    self.held[id] = nil
                    connection.cancel()
                    if let abandoned { DispatchQueue.main.async { abandoned(id) } }
                    return
                }
                watch()
            }
        }
        watch()
    }
}
