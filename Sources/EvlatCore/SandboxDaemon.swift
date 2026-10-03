import Foundation

/// A Docker sandbox's life as the `sbx` daemon tells it: one
/// `sandbox.lifecycle` event from its `/events` stream.
public struct SandboxEvent: Equatable {
    public enum Action: Equatable {
        case created, started, stopped, deleted
        /// A word this version does not know: kept, and counted
        /// (`SandboxDaemon.Stream.unknownActions`), never taken for another.
        case unknown(String)

        init(_ word: String) {
            switch word {
            case "created": self = .created
            case "started": self = .started
            case "stopped": self = .stopped
            case "deleted": self = .deleted
            default: self = .unknown(word)
            }
        }
    }

    /// The sandbox's name as the daemon says it. Not checked here: a
    /// command is made for it only if it reads as one
    /// (`SandboxInstall.isSandboxName`).
    public let name: String
    /// The daemon's id for the sandbox (`sandbox_id`), when it gave one.
    public let id: String?
    public let action: Action

    public init(name: String, id: String?, action: Action) {
        self.name = name
        self.id = id
        self.action = action
    }
}

/// The `sbx` daemon's event stream, read without a socket: the request to
/// send on its unix socket and a decoder for what comes back. The shell
/// holds the connection; this says what the bytes mean.
///
/// Undocumented and internal to `sbx` (0.46.0, measured): `GET /events`
/// answers `HTTP/1.1 200` with `application/x-ndjson`, chunked, one JSON
/// object per line (`type`, `action`, `sandbox_name`, `sandbox_id`, `id`,
/// `created_at`, `timestamp`, `data`). Evlat only hears from it; every
/// change goes through the `sbx` CLI.
public enum SandboxDaemon {
    /// The request, whole.
    public static let request = Data("GET /events HTTP/1.1\r\nHost: localhost\r\nAccept: application/x-ndjson\r\n\r\n".utf8)

    /// The one event type decoded. Every other line — `policy.network`
    /// arrives for each network request a sandbox makes — is passed over
    /// by a substring check, without parsing it.
    public static let lifecycle = "sandbox.lifecycle"

    // MARK: - Reconnecting

    /// The first wait after the connection fails or ends.
    public static let initialDelay: TimeInterval = 1
    /// The longest wait: the daemon comes back with Docker Desktop, and a
    /// sandbox started meanwhile is set up when the list is read again.
    public static let maximumDelay: TimeInterval = 60
    /// A connection that lived this long was a good one: its end starts
    /// the schedule over.
    public static let stableAfter: TimeInterval = 60

    /// The wait after `failures` consecutive failures (1 = the first),
    /// doubling up to `maximumDelay` (`RemoteTunnel.delay`'s shape).
    public static func delay(afterFailures failures: Int) -> TimeInterval {
        guard failures > 0 else { return 0 }
        let doublings = min(failures - 1, 16)
        return min(initialDelay * pow(2, Double(doublings)), maximumDelay)
    }

    /// The failure count once a connection ends at `now`: it starts over
    /// at 1 if the connection was up (`connectedAt`) for `stableAfter`,
    /// else it grows by one. The clock is the caller's.
    public static func failures(after previous: Int, connectedAt: Date?, now: Date) -> Int {
        if let connectedAt, now.timeIntervalSince(connectedAt) >= stableAfter { return 1 }
        return previous + 1
    }

    // MARK: - Decoding

    /// The response, fed as its bytes arrive, in pieces of any size. Pure
    /// state; one per connection.
    public struct Stream {
        public enum Failure: Equatable {
            /// Not `200`; `nil` when the status line did not parse.
            case status(Int?)
            /// Not the NDJSON stream this was measured with.
            case contentType(String?)
            /// The head or a chunk size could not be read.
            case framing
        }

        /// Set once: the stream is not one, and nothing more is read.
        public private(set) var failure: Failure?
        /// The last chunk (`0`) arrived: the daemon ended the stream.
        public private(set) var ended = false
        /// The head was a `200` with the NDJSON type: the stream is the one
        /// measured, and the connection counts as made only from here.
        public private(set) var opened = false
        /// Lifecycle events whose action was not a known word.
        public private(set) var unknownActions = 0
        /// Lines that said `sandbox.lifecycle` but were not an event: no
        /// JSON object, no name, or longer than `lineLimit`.
        public private(set) var malformedLines = 0

        /// The longest head and the longest line kept; past them the head
        /// fails and the line is dropped.
        public static let headLimit = 16 * 1024
        public static let lineLimit = 1024 * 1024

        private enum Frame {
            case head
            case size
            case data(Int)
            case dataEnd
            case identity
        }

        // A plain array, zero-based whatever the slices fed in were: a
        // `Data` slice keeps its parent's indices (`AGENTS.md` → Pitfalls).
        private var buffer: [UInt8] = []
        private var line: [UInt8] = []
        private var droppingLine = false
        private var frame = Frame.head

        public init() {}

        /// Reads `bytes`, returning the events completed by them.
        public mutating func feed(_ bytes: Data) -> [SandboxEvent] {
            guard failure == nil, !ended else { return [] }
            buffer.append(contentsOf: bytes)
            var events: [SandboxEvent] = []
            while failure == nil, !ended, step(into: &events) {}
            return events
        }

        /// One step of the framing; `false` when it needs more bytes.
        private mutating func step(into events: inout [SandboxEvent]) -> Bool {
            switch frame {
            case .head:
                guard let end = Self.find([13, 10, 13, 10], in: buffer) else {
                    if buffer.count > Self.headLimit { failure = .framing }
                    return false
                }
                let head = String(decoding: buffer[0..<end], as: UTF8.self)
                buffer.removeFirst(end + 4)
                frame = readHead(head) ?? .head
                return true
            case .size:
                guard let end = Self.find([13, 10], in: buffer) else {
                    if buffer.count > 1024 { failure = .framing }
                    return false
                }
                let text = String(decoding: buffer[0..<end], as: UTF8.self)
                buffer.removeFirst(end + 2)
                // An extension after `;` says nothing to this reader.
                let digits = text.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)[0]
                    .trimmingCharacters(in: .whitespaces)
                // Hex digits only: `Int(_:radix:)` takes a sign, and a
                // negative size would make a range that traps.
                guard !digits.isEmpty, digits.count <= 8, digits.allSatisfy(\.isHexDigit),
                      let size = Int(digits, radix: 16) else {
                    failure = .framing
                    return false
                }
                if size == 0 { ended = true; return false }
                frame = .data(size)
                return true
            case .data(let remaining):
                guard !buffer.isEmpty else { return false }
                let count = min(remaining, buffer.count)
                body(buffer[0..<count], into: &events)
                buffer.removeFirst(count)
                frame = count == remaining ? .dataEnd : .data(remaining - count)
                return true
            case .dataEnd:
                guard buffer.count >= 2 else { return false }
                guard buffer[0] == 13, buffer[1] == 10 else { failure = .framing; return false }
                buffer.removeFirst(2)
                frame = .size
                return true
            case .identity:
                guard !buffer.isEmpty else { return false }
                body(buffer[...], into: &events)
                buffer.removeAll(keepingCapacity: true)
                return true
            }
        }

        /// The status line and headers; the frame the body is read in, or
        /// `nil` with `failure` set.
        private mutating func readHead(_ head: String) -> Frame? {
            let lines = head.components(separatedBy: "\r\n")
            let status = lines.first?.split(separator: " ", maxSplits: 2)
            guard let status, status.count >= 2, status[0].hasPrefix("HTTP/1."), let code = Int(status[1]) else {
                failure = .status(nil)
                return nil
            }
            guard code == 200 else { failure = .status(code); return nil }
            var type: String?
            var chunked = false
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                switch name {
                case "content-type": type = value
                case "transfer-encoding": chunked = value.lowercased().contains("chunked")
                default: break
                }
            }
            guard let type, type.lowercased().hasPrefix("application/x-ndjson") else {
                failure = .contentType(type)
                return nil
            }
            opened = true
            return chunked ? .size : .identity
        }

        /// The body's bytes, cut into lines.
        private mutating func body(_ bytes: ArraySlice<UInt8>, into events: inout [SandboxEvent]) {
            var rest = bytes[...]
            while let newline = rest.firstIndex(of: 10) {
                if droppingLine {
                    droppingLine = false
                } else {
                    line.append(contentsOf: rest[rest.startIndex..<newline])
                    if let event = decode(line) { events.append(event) }
                }
                line.removeAll(keepingCapacity: true)
                rest = rest[rest.index(after: newline)...]
            }
            guard !droppingLine else { return }
            line.append(contentsOf: rest)
            if line.count > Self.lineLimit {
                line.removeAll()
                droppingLine = true
                malformedLines += 1
            }
        }

        /// One line: an event, or `nil` for any other type, a blank line,
        /// or a broken one (counted).
        private mutating func decode(_ line: [UInt8]) -> SandboxEvent? {
            guard Self.find(Array(SandboxDaemon.lifecycle.utf8), in: line) != nil else { return nil }
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
                malformedLines += 1
                return nil
            }
            // The word may sit in another type's data; only the type counts.
            guard object["type"] as? String == SandboxDaemon.lifecycle else { return nil }
            guard let name = object["sandbox_name"] as? String, !name.isEmpty,
                  let word = object["action"] as? String else {
                malformedLines += 1
                return nil
            }
            let action = SandboxEvent.Action(word)
            if case .unknown = action { unknownActions += 1 }
            return SandboxEvent(name: name, id: object["sandbox_id"] as? String, action: action)
        }

        /// Where `pattern` first starts in `bytes` (zero-based), or `nil`.
        private static func find(_ pattern: [UInt8], in bytes: [UInt8]) -> Int? {
            guard !pattern.isEmpty, bytes.count >= pattern.count else { return nil }
            let first = pattern[0]
            var index = 0
            let last = bytes.count - pattern.count
            while index <= last {
                if bytes[index] == first, bytes[index..<index + pattern.count].elementsEqual(pattern) { return index }
                index += 1
            }
            return nil
        }
    }
}
