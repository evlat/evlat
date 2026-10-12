import XCTest
import EvlatCore
@testable import EvlatApp

/// A session in a service many terminals share has no pid of its own, and its
/// tab is inferred from the service's clients (`ServiceClients`, the card's
/// `DetailModel` branch). The world below is the one measured on a 2.0
/// service: one program that is the service and every TUI, a TUI holding one
/// to three connections to the port the service listens on, each in the
/// folder it was started in.
@MainActor
final class ServiceClientsTests: XCTestCase {
    struct Proc {
        let parent: Int32
        var path: String? = Self.program
        var app: SessionHost.App? = nil
        var terminal: Bool? = true
        var cwd: String? = nil
        var environment: [String] = []
        var connections: [SessionHost.Endpoint] = []
        var listening: [SessionHost.Endpoint]? = nil

        static let program = "/Users/u/.opencode/bin/opencode"
    }

    nonisolated static let service: Int32 = 4183
    nonisolated static let port = SessionHost.Endpoint(address: "127.0.0.1", port: 49374)
    let bateri = SessionHost.App(bundleID: "dev.bateri.bateri", name: "Bateri", pid: 580)
    let metalterm = SessionHost.App(bundleID: "dev.metalterm.Metalterm", name: "Metalterm", pid: 500)

    static func tab(_ pid: Int32) -> String { String(format: "00000000-0000-4000-8000-%012d", pid) }

    /// A TUI in a tab of Bateri, `connections` to the service in its folder.
    func tui(_ pid: Int32, in folder: String, connections: Int = 3, shell: Int32? = nil,
             app: Int32 = 580) -> [Int32: Proc] {
        let shell = shell ?? pid - 1
        return [pid: Proc(parent: shell, cwd: folder, environment: ["BATERI_TAB_URL=bateri://tab/\(Self.tab(pid))"],
                          connections: Array(repeating: Self.port, count: connections)),
                shell: Proc(parent: app, path: "/bin/zsh", terminal: true)]
    }

    var base: [Int32: Proc] {
        [Self.service: Proc(parent: 1, terminal: false, cwd: "/Users/u",
                            connections: [SessionHost.Endpoint(address: "104.18.0.1", port: 443)],
                            listening: [Self.port]),
         580: Proc(parent: 1, path: "/Applications/Bateri.app/Contents/MacOS/bateri", app: bateri),
         500: Proc(parent: 1, path: "/Applications/Metalterm.app/Contents/MacOS/Metalterm", app: metalterm)]
    }

    func table(_ parts: [Int32: Proc]...) -> [Int32: Proc] {
        parts.reduce(base) { $0.merging($1) { a, _ in a } }
    }

    func probe(_ table: [Int32: Proc]) -> SessionHost.Probe {
        var probe = SessionHost.Probe(
            parent: { table[$0]?.parent },
            regularApp: { table[$0]?.app },
            executablePath: { table[$0]?.path },
            bundle: { _ in nil },
            running: { _ in nil },
            environment: { table[$0]?.environment ?? [] },
            processes: { Array(table.keys) },
            hasTerminal: { table[$0]?.terminal ?? nil },
            tcpSockets: { pid in
                table[pid].map { proc in
                    proc.connections.map { SessionHost.TCPSocket(local: .init(address: "127.0.0.1", port: 56000), remote: $0) }
                }
            },
            currentDirectory: { table[$0]?.cwd })
        probe.listeningSockets = { table[$0]?.listening }
        return probe
    }

    func resolve(_ table: [Int32: Proc], folder: String? = "/Users/u/api", service: Int32 = ServiceClientsTests.service,
                 realPath: ((String) -> String?)? = nil) -> SessionHost {
        var probe = probe(table)
        if let realPath { probe.realPath = realPath }
        return ServiceClients.resolve(service: service, folder: folder, probe)
    }

    func tab(_ host: SessionHost) -> String? {
        guard case .app(let app) = host else { return nil }
        return app.tab?.absoluteString
    }

    // MARK: - Which client

    /// Each session's tab is its own client's, found by the folder it runs
    /// in, one connection or three alike.
    func testEachSessionFindsTheClientInItsFolder() {
        let t = table(tui(5001, in: "/Users/u/api", connections: 3), tui(6001, in: "/Users/u/web", connections: 1))
        XCTAssertEqual(tab(resolve(t, folder: "/Users/u/api")), "bateri://tab/\(Self.tab(5001))")
        XCTAssertEqual(tab(resolve(t, folder: "/Users/u/web")), "bateri://tab/\(Self.tab(6001))")
        XCTAssertEqual(ServiceClients.clients(of: Self.service, in: "/Users/u/api", probe(t)), [5001])
    }

    /// Two tabs in one folder cannot be told apart: the app alone, never
    /// either tab; two apps, nothing.
    func testTwoClientsInOneFolderBringTheAppAloneOrNothing() {
        let sameApp = table(tui(5001, in: "/Users/u/api"), tui(6001, in: "/Users/u/api"))
        guard case .app(let app) = resolve(sameApp) else { return XCTFail("one app holds both") }
        XCTAssertEqual(app.bundleID, bateri.bundleID)
        XCTAssertNil(app.tab, "it may be either")
        let twoApps = table(tui(5001, in: "/Users/u/api"), tui(6001, in: "/Users/u/api", shell: 6000, app: 500))
        XCTAssertEqual(resolve(twoApps), .notFound)
    }

    /// A TUI is in the session's folder, not above or below it: one opened in
    /// a subfolder has that subfolder as its directory (measured), and a
    /// session of the parent is not its.
    func testTheFolderIsTheClientsOwnNotAnAncestorsNorADescendants() {
        let t = table(tui(5001, in: "/Users/u/api/src"))
        XCTAssertEqual(tab(resolve(t, folder: "/Users/u/api/src")), "bateri://tab/\(Self.tab(5001))")
        XCTAssertEqual(resolve(t, folder: "/Users/u/api"), .notFound)
        XCTAssertEqual(resolve(t, folder: "/Users/u/api/src/deep"), .notFound)
    }

    /// The same folder reached by two spellings (`/var` and `/private/var`,
    /// as a 2.x service names its locations) is one.
    func testAFolderBySeveralSpellingsIsOne() {
        let t = table(tui(5001, in: "/private/var/folders/x/api"))
        XCTAssertEqual(resolve(t, folder: "/var/folders/x/api"), .notFound, "compared as written")
        let real: (String) -> String? = { $0.hasPrefix("/var/") ? "/private" + $0 : $0 }
        XCTAssertEqual(tab(resolve(t, folder: "/var/folders/x/api", realPath: real)), "bateri://tab/\(Self.tab(5001))")
    }

    // MARK: - Who is not a client

    func testWhoIsNotAClient() {
        let other = SessionHost.Endpoint(address: "127.0.0.1", port: 50001)
        let lan = SessionHost.Endpoint(address: "10.0.0.5", port: 49374)
        var standalone = tui(7001, in: "/Users/u/api")
        standalone[7001]?.connections = [other]
        var elsewhere = tui(7101, in: "/Users/u/api")
        elsewhere[7101]?.connections = [lan]
        var headless = tui(7201, in: "/Users/u/api")
        headless[7201]?.terminal = false
        var node = tui(7301, in: "/Users/u/api")
        node[7301]?.path = "/usr/local/bin/node"
        var unreadable = tui(7401, in: "/Users/u/api")
        unreadable[7401]?.terminal = nil
        for (why, extra) in [("a TUI of its own (standalone) is connected to its own child, not the service", standalone),
                             ("a connection to another machine's port of the same number", elsewhere),
                             ("a client without a terminal", headless),
                             ("another program", node),
                             ("a terminal that cannot be read", unreadable)] {
            XCTAssertEqual(ServiceClients.clients(of: Self.service, in: "/Users/u/api", probe(table(extra))), [], why)
            XCTAssertEqual(resolve(table(extra)), .notFound, why)
        }
    }

    /// The service itself holds connections and has a directory, and is the
    /// same program: it is never its own client, whatever it is connected to.
    func testTheServiceIsNotItsOwnClient() {
        var t = base
        t[Self.service]?.terminal = true
        t[Self.service]?.cwd = "/Users/u/api"
        t[Self.service]?.connections = [Self.port]
        XCTAssertEqual(ServiceClients.clients(of: Self.service, in: "/Users/u/api", probe(t)), [])
    }

    /// A service whose sockets cannot be read, one that listens on nothing, a
    /// session with no folder or only a relative one: nothing is guessed.
    func testWhatCannotBeReadNamesNobody() {
        let clients = tui(5001, in: "/Users/u/api")
        var unreadable = table(clients)
        unreadable[Self.service]?.listening = nil
        XCTAssertEqual(resolve(unreadable), .notFound)
        var silent = table(clients)
        silent[Self.service]?.listening = []
        XCTAssertEqual(resolve(silent), .notFound)
        var gone = table(clients)
        gone[Self.service] = nil
        XCTAssertEqual(resolve(gone), .notFound)
        XCTAssertEqual(resolve(table(clients), folder: nil), .notFound)
        XCTAssertEqual(resolve(table(clients), folder: "api"), .notFound)
        var blind = table(clients)
        blind[5001]?.connections = []
        XCTAssertEqual(resolve(blind), .notFound)
    }

    /// A service that listens on a wildcard address is reached on loopback.
    func testAWildcardListenerIsReachedOnLoopback() {
        var t = table(tui(5001, in: "/Users/u/api"))
        t[Self.service]?.listening = [SessionHost.Endpoint(address: "0.0.0.0", port: 49374)]
        XCTAssertEqual(ServiceClients.clients(of: Self.service, in: "/Users/u/api", probe(t)), [5001])
        XCTAssertTrue(ServiceClients.reaches(.init(address: "::1", port: 49374), .init(address: "::", port: 49374)))
        XCTAssertFalse(ServiceClients.reaches(.init(address: "::1", port: 49375), .init(address: "::", port: 49374)))
    }

    // MARK: - The card

    private func signal(servicePid: Int32?, pid: Int32? = nil, folder: String = "/Users/u/api",
                        entity: String = "s-1") -> Signal {
        Signal(provider: "hooks", entity: entity, phase: .working, label: "api", detail: folder,
               source: AgentID("opencode"), fidelity: .official, updatedAt: Date(timeIntervalSince1970: 0),
               activity: Signal.Activity(pid: pid, servicePid: servicePid))
    }

    /// A row with only its service's pid is looked up among the service's
    /// clients, once per card and again when the service or the folder
    /// changes; the click looks again. A row with a pid of its own is walked
    /// up from it, as before.
    func testTheCardLooksUpAServiceRowAmongTheClients() {
        let model = DetailModel()
        var services: [(Int32, String?)] = []
        var walks: [Int32?] = []
        model.resolveService = { pid, folder in services.append((pid, folder)); return .app(self.bateri) }
        model.resolveHost = { pid in walks.append(pid); return .notFound }
        model.activate = { _ in true }

        let row = signal(servicePid: 900)
        model.update(row: SessionRow(row), signal: row)
        model.update(row: SessionRow(row), signal: row)
        XCTAssertEqual(services.count, 1, "cached for the card")
        XCTAssertEqual(services.first?.0, 900)
        XCTAssertEqual(services.first?.1, "/Users/u/api")
        XCTAssertEqual(model.detail?.host, .app(bateri))
        XCTAssertTrue(walks.isEmpty, "no pid to walk up from")

        let restarted = signal(servicePid: 901)
        model.update(row: SessionRow(restarted), signal: restarted)
        XCTAssertEqual(services.map(\.0), [900, 901], "a new service is looked up again")
        let moved = signal(servicePid: 901, folder: "/Users/u/web")
        model.update(row: SessionRow(moved), signal: moved)
        XCTAssertEqual(services.map(\.1), ["/Users/u/api", "/Users/u/api", "/Users/u/web"])

        XCTAssertTrue(model.go())
        XCTAssertEqual(services.count, 4, "the click asks again")

        let own = signal(servicePid: nil, pid: 4242)
        model.update(row: SessionRow(own), signal: own)
        XCTAssertEqual(walks, [4242])
        XCTAssertEqual(services.count, 4)
        let both = signal(servicePid: 900, pid: 4242, entity: "s-2")
        model.update(row: SessionRow(both), signal: both)
        XCTAssertEqual(walks, [4242, 4242], "its own pid wins")
        XCTAssertEqual(services.count, 4)
    }
}
