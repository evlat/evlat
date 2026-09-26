import Foundation

/// One HTTP/1.1 request, as far as the local endpoint cares about it.
///
/// Pure bytes in, values out: no socket is involved, which is what lets the
/// whole contract be tested without opening one. The transport that feeds this
/// lives in `EvlatApp`.
///
/// Only six headers are read, and each has a job: `X-Evlat-Task` and
/// `X-Evlat-Pid` are what the installed hook command sends, `Origin` and `Host`
/// are what tell a browser apart from a `curl` (`LocalAPI.dispatch`),
/// `X-Evlat-Permission` is the token a chat's own permission hook carries
/// (`PermissionHook`), and `X-Evlat-Key` is an outside program's key
/// for `/signal`.
public struct HTTPRequest: Equatable {
    public let method: String
    /// The request line's target: path **and** query, exactly as written.
    public let target: String
    public let body: Data
    /// `X-Evlat-Task`: the Evlat errand that caused the event.
    public let taskID: String?
    /// `X-Evlat-Pid`: the agent process that sent it. Validated in `HookEvent`,
    /// where it is read; here it is only text off the wire.
    public let pid: String?
    /// `Origin`: only a browser sends it. An **empty value still counts** —
    /// the line being there is the mark.
    public let origin: String?
    /// `Host`: in a DNS rebinding attempt this still carries the page's own
    /// name, even though `Origin` is absent.
    public let host: String?
    /// `X-Evlat-Permission`: which chat turn a permission request belongs
    /// to. Matched against the running turns on the main queue (`ChatStore`),
    /// never here — a token is state, this type is not.
    public let permissionToken: String?
    /// `X-Evlat-Key`: the key `/signal` asks for (`SignalReport.keyHeader`).
    /// Compared against the listener's own on the server queue
    /// (`LocalAPI.Listener`); empty counts as absent, so it can never match.
    public let signalKey: String?

    public init(method: String, target: String, body: Data = Data(),
                taskID: String? = nil, pid: String? = nil,
                origin: String? = nil, host: String? = nil, permissionToken: String? = nil,
                signalKey: String? = nil) {
        self.method = method
        self.target = target
        self.body = body
        self.taskID = taskID
        self.pid = pid
        self.origin = origin
        self.host = host
        self.permissionToken = permissionToken
        self.signalKey = signalKey
    }

    /// `nil` means "not yet": either the header block has not arrived or the
    /// announced body has not. The caller keeps reading. It never means the
    /// request is refused — that decision belongs to `LocalAPI.dispatch`.
    ///
    /// Every index below is `data`'s own, never a literal `0` and never
    /// `count`. A listener's buffer that has already had one request taken out
    /// of it starts part way in, and `Data`'s indices stay **absolute** across
    /// such a slice: `0..<headerEnd.lowerBound` traps on it, and `count` as an
    /// end index makes a request that has fully arrived look incomplete for
    /// ever.
    public static func parse(_ data: Data) -> HTTPRequest? {
        // Latin-1, not UTF-8: a header byte that is not valid UTF-8 would
        // decode to `nil`, which this function means as "keep reading" — and no
        // byte arriving later can fix it, so the connection would be held open
        // until the client's own timeout. Latin-1 cannot fail, and the four
        // header values read here are compared as ASCII anyway.
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)),
              let header = String(data: data.subdata(in: data.startIndex..<headerEnd.lowerBound),
                                  encoding: .isoLatin1)
        else { return nil }
        let lines = header.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ") ?? []
        guard requestLine.count >= 2 else { return nil }

        var contentLength = 0
        var taskID: String?
        var pid: String?
        var origin: String?
        var host: String?
        var permissionToken: String?
        var signalKey: String?
        for line in lines.dropFirst() {
            // Empty pieces are kept: a valueless `Origin:` line is a browser's
            // mark too, and dropping it let the defence be walked past.
            let pair = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { continue }
            let name = pair[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = pair[1].trimmingCharacters(in: .whitespaces)
            switch name {
            // A negative length used to reverse the body slice and bring the
            // process down — one header from any local process was enough. A
            // length that cannot be read means "no body", and the request then
            // fails as a bad one where a body was expected.
            case "content-length": contentLength = max(0, Int(value) ?? 0)
            case "x-evlat-task": taskID = value.isEmpty ? nil : value
            case "x-evlat-pid": pid = value.isEmpty ? nil : value
            case "origin": origin = value
            case "host": host = value
            case "x-evlat-permission": permissionToken = value.isEmpty ? nil : value
            case "x-evlat-key": signalKey = value.isEmpty ? nil : value
            default: continue
            }
        }

        let bodyStart = headerEnd.upperBound
        guard data.endIndex - bodyStart >= contentLength else { return nil }
        return HTTPRequest(method: String(requestLine[0]), target: String(requestLine[1]),
                           // Exactly the announced length: whatever follows
                           // belongs to the next request on the connection.
                           body: data.subdata(in: bodyStart..<(bodyStart + contentLength)),
                           taskID: taskID, pid: pid, origin: origin, host: host,
                           permissionToken: permissionToken, signalKey: signalKey)
    }
}
