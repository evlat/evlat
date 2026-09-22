import Foundation
import Network
import EvlatCore

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
/// it silently receives no events — the opposite of this repo's discipline
/// (`discussion.md` → Karar 1). The call direction here is App → Core.
public final class HookListener {
    /// Where the endpoint stands. A failure to bind is a **value**, not a log
    /// line that scrolls away: the one way this feature breaks in the field is
    /// another Evlat (v1, same bundle id, same executable name) already holding
    /// the port, and then nothing at all happens — no crash, no event, no
    /// symptom. `--list` prints this.
    public enum Status: Equatable {
        case stopped
        /// Bound. The port is the one actually bound, which is not always the
        /// one asked for: `0` means "any free port" and is what tests use.
        case listening(UInt16)
        case unavailable(UInt16, String)

        public var text: String {
            switch self {
            case .stopped: return "not started"
            case .listening(let port): return "listening on 127.0.0.1:\(port)"
            case .unavailable(let port, let reason): return "port \(port) unavailable — \(reason)"
            }
        }
    }

    /// Which port to listen on, and what was ignored to get there.
    public struct PortChoice: Equatable {
        public let port: UInt16
        /// The `EVLAT_PORT` value that could not be used, if one was set. Kept
        /// so a typo is **visible** instead of quietly falling back to 48151
        /// and looking like a working endpoint.
        public let rejectedOverride: String?
    }

    private let requestedPort: UInt16
    private let onEvent: (HookEvent) -> Void
    private let onStatus: ((Status) -> Void)?
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

    /// `onEvent` is called on the **main queue** with an already-parsed event.
    /// The raw body is not carried across: it reaches 8 KB and nothing on the
    /// main queue wants it.
    ///
    /// `onStatus` is called on the main queue every time the endpoint's state
    /// changes. It is taken here rather than left as a settable property
    /// because it is read from the listener's queue: a caller assigning it
    /// after `start()` would be racing the first state report.
    public init(port: UInt16,
                onStatus: ((Status) -> Void)? = nil,
                onEvent: @escaping (HookEvent) -> Void) {
        self.requestedPort = port
        self.onStatus = onStatus
        self.onEvent = onEvent
    }

    public var status: Status {
        lock.lock(); defer { lock.unlock() }
        return currentStatus
    }

    /// The port to bind, from the environment.
    ///
    /// There is **no `UserDefaults` key** and there will not be one: v1 and v2
    /// ship the same bundle id, so a stored `"port"` would follow v1 too, while
    /// the number in the user's hook command is plain text. Both apps would
    /// listen somewhere else, neither would receive anything, and neither would
    /// report an error (`plan.md` → Göç). The override is an environment
    /// variable, the same shape `EVLAT_SESSIONS` already has.
    ///
    /// `0` is rejected as an override even though it is a valid port number to
    /// bind: it means "any free port", and an app reachable on a port nobody
    /// can guess is exactly the silent failure above.
    public static func resolvePort(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> PortChoice {
        guard let raw = environment["EVLAT_PORT"], !raw.isEmpty else {
            return PortChoice(port: LocalAPI.defaultPort, rejectedOverride: nil)
        }
        guard let value = UInt16(raw), value > 0 else {
            return PortChoice(port: LocalAPI.defaultPort, rejectedOverride: raw)
        }
        return PortChoice(port: value, rejectedOverride: nil)
    }

    /// Starts binding. It returns immediately; the result arrives through
    /// `status`, because `NWListener` reports "address already in use" through
    /// its state handler and not from the initialiser.
    public func start() {
        let parameters = NWParameters.tcp
        // Only the loopback interface. The endpoint takes no identity and acts
        // on what it is told, so it must not be reachable from the network the
        // machine is on. `lsof` still prints it as `*:48151`; that is the
        // socket's address family, not its reachability.
        parameters.requiredInterfaceType = .loopback
        // Rebinding right after a restart otherwise fails while the previous
        // socket sits in TIME_WAIT — `make calistir` replaces the process in
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
                self.setStatus(.listening(listener?.port?.rawValue ?? self.requestedPort))
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

    public func stop() {
        listener?.cancel()
        listener = nil
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

    /// The answer is written from **this** queue and the event is handed to the
    /// main queue afterwards.
    ///
    /// The installed command runs `curl -s -m 2` under a hook with `timeout: 5`,
    /// so the agent is waiting on this write. Answering from the main queue
    /// would put the agent behind whatever the UI is doing — v1 kept a
    /// semaphore for that and used it only on its read endpoints, never here.
    private func respond(_ connection: NWConnection, to request: HTTPRequest) {
        let outcome = LocalAPI.handle(request)
        connection.send(content: Data(outcome.response.httpText.utf8),
                        completion: .contentProcessed { _ in connection.cancel() })
        guard let event = outcome.event else { return }
        let deliver = onEvent
        DispatchQueue.main.async { deliver(event) }
    }
}
