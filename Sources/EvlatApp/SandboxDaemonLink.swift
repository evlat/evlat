import Foundation
import Network
import EvlatCore

/// The connection to the `sbx` daemon's event stream (`SandboxDaemon`): one
/// long-lived `GET /events` on its unix socket, read on its own queue and
/// handed to the main queue as lifecycle events. The bytes' meaning is the
/// core's; this is only the transport.
///
/// Evlat only hears from it. When it fails or ends it is opened again after
/// the core's growing delay (`SandboxDaemon.delay`), never in a tight loop;
/// a connection that lived `SandboxDaemon.stableAfter` starts the schedule
/// over.
final class SandboxDaemonLink {
    enum State: Equatable {
        case connecting
        /// The daemon answered the request with the stream measured
        /// (`SandboxDaemon.Stream.opened`); an open socket alone is not it.
        case connected
        /// Ended, or no socket; the next try is scheduled.
        case disconnected
        /// The daemon answered, but not with the stream measured (another
        /// status, type or framing): `sbx` runs, Evlat cannot read it. The
        /// next try is scheduled as for `disconnected`.
        case refused
    }

    let socketPath: String
    private let delay: (Int) -> TimeInterval
    private let now: () -> Date
    private let onState: (State) -> Void
    private let onEvent: (SandboxEvent) -> Void
    private let queue = DispatchQueue(label: "dev.kalaomer.evlat.sandboxd")

    // `queue` only.
    private var connection: NWConnection?
    private var stream = SandboxDaemon.Stream()
    private var failures = 0
    private var connectedAt: Date?
    private var stopped = true
    /// Which connection a callback is for: a late callback of an ended one
    /// must not end its successor.
    private var generation = 0

    /// `onState` and `onEvent` are called on the main queue. `delay` and
    /// `now` are the test's; the launch uses the core's schedule and the
    /// clock.
    init(socketPath: String,
         delay: @escaping (Int) -> TimeInterval = SandboxDaemon.delay(afterFailures:),
         now: @escaping () -> Date = Date.init,
         onState: @escaping (State) -> Void,
         onEvent: @escaping (SandboxEvent) -> Void) {
        self.socketPath = socketPath
        self.delay = delay
        self.now = now
        self.onState = onState
        self.onEvent = onEvent
    }

    func start() {
        queue.async { [self] in
            guard stopped else { return }
            stopped = false
            failures = 0
            connect()
        }
    }

    /// Closes the stream; no try follows.
    func stop() {
        queue.async { [self] in
            stopped = true
            generation += 1
            connection?.cancel()
            connection = nil
        }
    }

    // MARK: - On `queue`

    private func connect() {
        guard !stopped else { return }
        connection?.cancel()
        generation += 1
        let current = generation
        stream = SandboxDaemon.Stream()
        connectedAt = nil
        let connection = NWConnection(to: .unix(path: socketPath), using: .tcp)
        self.connection = connection
        report(.connecting)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, current == self.generation else { return }
            switch state {
            case .ready:
                connection.send(content: SandboxDaemon.request, completion: .contentProcessed { _ in })
                self.receive(on: connection, generation: current)
            // A missing socket waits for a path that never comes: a
            // failure like any other.
            case .waiting, .failed:
                self.end(current)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receive(on connection: NWConnection, generation current: Int) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self, current == self.generation else { return }
            if let data, !data.isEmpty {
                let events = self.stream.feed(data)
                // Connected once the head says it is the stream: a daemon
                // that answers otherwise must not set the sandboxes up again
                // on every try.
                if self.stream.opened, self.connectedAt == nil {
                    self.connectedAt = self.now()
                    self.report(.connected)
                }
                if !events.isEmpty {
                    let onEvent = self.onEvent
                    DispatchQueue.main.async { events.forEach(onEvent) }
                }
            }
            if let failure = self.stream.failure {
                NSLog("Evlat: sandbox daemon stream refused: %@", String(describing: failure))
                return self.end(current, refused: true)
            }
            guard !complete, error == nil, !self.stream.ended else { return self.end(current) }
            self.receive(on: connection, generation: current)
        }
    }

    /// The connection `current` is over: the next one after the delay.
    private func end(_ current: Int, refused: Bool = false) {
        guard current == generation else { return }
        generation += 1
        connection?.cancel()
        connection = nil
        failures = SandboxDaemon.failures(after: failures, connectedAt: connectedAt, now: now())
        report(refused ? .refused : .disconnected)
        guard !stopped else { return }
        // Only if nothing else started one meanwhile (a stop and a start).
        let scheduled = generation
        queue.asyncAfter(deadline: .now() + delay(failures)) { [weak self] in
            guard let self, scheduled == self.generation else { return }
            self.connect()
        }
    }

    private func report(_ state: State) {
        let onState = self.onState
        DispatchQueue.main.async { onState(state) }
    }
}
