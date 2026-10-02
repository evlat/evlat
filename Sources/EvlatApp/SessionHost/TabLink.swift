import Foundation

/// Apps that tell the agent which of their tabs it runs in, in a variable
/// it inherits. Opening the tab's link is the app's own way to select it —
/// no permission — and every handler here only shows: no byte reaches the
/// shell, nothing runs.
///
/// - Bateri, Metalterm and Warp hand each shell its tab's link ready made
///   (Bateri's `open_urls`, Metalterm's `tab/`, Warp's `WARP_FOCUS_URL`).
/// - iTerm hands it `ITERM_SESSION_ID` (`w0t0p0:<UUID>`), and
///   `iterm2:reveal?sessionid=` that whole value reveals the session: iTerm
///   splits it at the `:` and looks the UUID up (`revealSessionID:`), so the
///   UUID alone finds nothing. Of iTerm's URL commands this is the only one
///   used — others run commands.
/// - Claude's desktop app hands its Claude Code sessions their own id, and
///   `claude://code/continue?session=<id>` opens that session — the link its
///   own "Continue" menu and Spotlight entries use. An id it no longer knows
///   opens its Claude Code home, never another session. Undocumented: if it
///   changes, the app still comes forward.
/// - cmux hands each shell `CMUX_WORKSPACE_ID` and `CMUX_SURFACE_ID`, and
///   `cmux://workspace/<id>/surface/<id>` selects that tab — its navigation
///   link (`CmuxNavigationURLRequest` in cmux's source; seen working on
///   0.64.25). Its socket refuses a process started outside cmux, so the
///   link is the one way in.
///
/// The value is checked, not trusted: it is whatever the agent's environment
/// says, and `metalterm://tab/restart` is an action, not a tab. Bateri's ids
/// are UUIDs, Metalterm's 16 hex digits, Warp's 32, iTerm's a UUID after its
/// position, Claude's `local_` and a UUID (the app accepts
/// `local_[A-Za-z0-9-]{1,64}`), cmux's two UUIDs.
///
/// Terminal and Ghostty publish nothing an app can open: choosing their tab
/// takes Apple Events, a permission, so they are only brought forward.
///
/// An app may also hand the same values in `LC_*` variables (`forwarded`):
/// `ssh`'s default `SendEnv LANG LC_*` and the servers' `AcceptEnv LANG LC_*`
/// carry them to a remote session, where the server reads them
/// (`RemoteHost`) — on this Mac the `ssh` that carried them is Apple's, whose
/// environment no other process can read. The value is checked by the same
/// rule as on this Mac, and only for the app the walk reached. The table is
/// the only place a terminal is named: the server's script gets the names
/// as arguments.
struct TabLink {
    /// Read in this order; every one must be there.
    let variables: [String]
    /// The same values under the names they cross `ssh` with, in the same
    /// order; empty when the app forwards none.
    let forwarded: [String]
    /// The link, from the variables' values; `nil` when they are not one.
    let link: ([Substring]) -> URL?

    init(variable: String, forwarded: String? = nil, link: @escaping (Substring) -> URL?) {
        variables = [variable]
        self.forwarded = forwarded.map { [$0] } ?? []
        self.link = { values in values.first.flatMap(link) }
    }

    init(variables: [String], forwarded: [String] = [], link: @escaping ([Substring]) -> URL?) {
        self.variables = variables
        self.forwarded = forwarded
        self.link = link
    }

    static let known: [String: TabLink] = [
        // Bateri ships as `dev.bateri.bateri` (seen installed); the older
        // id stays for copies built before the change.
        "dev.bateri.bateri": ready(variable: "BATERI_TAB_URL", forwarded: "LC_BATERI_TAB_URL",
                                   prefix: "bateri://tab/"),
        "io.github.bateri.bateri": ready(variable: "BATERI_TAB_URL", forwarded: "LC_BATERI_TAB_URL",
                                         prefix: "bateri://tab/"),
        "dev.metalterm.Metalterm": ready(variable: "METALTERM_TAB_URL", prefix: "metalterm://tab/"),
        "dev.warp.Warp-Stable": ready(variable: "WARP_FOCUS_URL", prefix: "warp://session/"),
        "com.googlecode.iterm2": TabLink(variable: "ITERM_SESSION_ID") { value in
            guard let colon = value.firstIndex(of: ":"),
                  isID(value[..<colon], alphanumeric: true),
                  isID(value[value.index(after: colon)...], alphanumeric: false) else { return nil }
            return URL(string: "iterm2:reveal?sessionid=\(value)")
        },
        "com.anthropic.claudefordesktop": TabLink(variable: "CLAUDE_CODE_HOST_SESSION_ID") { value in
            guard value.hasPrefix("local_"), isID(value.dropFirst("local_".count), alphanumeric: true) else {
                return nil
            }
            return URL(string: "claude://code/continue?session=\(value)")
        },
        "com.cmuxterm.app": TabLink(variables: ["CMUX_WORKSPACE_ID", "CMUX_SURFACE_ID"]) { values in
            guard values.count == 2, let workspace = UUID(uuidString: String(values[0])),
                  let surface = UUID(uuidString: String(values[1])) else { return nil }
            return URL(string: "cmux://workspace/\(workspace.uuidString)/surface/\(surface.uuidString)")
        },
    ]

    /// A variable that holds the link itself: `<prefix><hex id>`.
    private static func ready(variable: String, forwarded: String? = nil, prefix: String) -> TabLink {
        TabLink(variable: variable, forwarded: forwarded) { value in
            guard value.hasPrefix(prefix), isID(value.dropFirst(prefix.count), alphanumeric: false) else {
                return nil
            }
            return URL(string: String(value))
        }
    }

    /// 1–64 ASCII characters: hex digits (or any letter and digit) and `-`.
    /// Nothing that could start a path, a query or a fragment.
    private static func isID(_ id: Substring, alphanumeric: Bool) -> Bool {
        (1...64).contains(id.count) && id.allSatisfy { character in
            character.isASCII && (character == "-" || character.isHexDigit
                                  || (alphanumeric && (character.isLetter || character.isNumber)))
        }
    }

    static func of(_ bundleID: String) -> TabLink? { known[bundleID] }

    /// The tab's link for that app, from the agent's environment; `nil` for
    /// another app, a missing variable or a value that is not one. The first
    /// occurrence counts, as `getenv` reads it.
    /// With `forwarded`, the values are read under the names they cross
    /// `ssh` with (`NAME=value` lines from the server, `RemoteHost`).
    static func url(bundleID: String, environment: [String], forwarded: Bool = false) -> URL? {
        guard let entry = of(bundleID) else { return nil }
        let names = forwarded ? entry.forwarded : entry.variables
        guard !names.isEmpty else { return nil }
        var values: [Substring] = []
        for variable in names {
            guard let value = SessionHost.value(variable, in: environment) else { return nil }
            values.append(Substring(value))
        }
        return entry.link(values)
    }

    /// Every name a value crosses `ssh` with, sorted: what the server's
    /// script is asked to read.
    static var forwardedNames: [String] {
        Set(known.values.flatMap(\.forwarded)).sorted()
    }
}
