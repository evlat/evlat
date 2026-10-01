import AppKit
import Darwin

/// The real lookups behind `SessionHost.live`: what any process may read of
/// its user's own, without a permission — `sysctl`, `proc_pidpath`,
/// `proc_pidinfo`, `Bundle` and `NSRunningApplication`.
extension SessionHost {
    /// The process's `kinfo_proc`. `sysctl` answers an unknown pid with
    /// success and an empty result, so the size is checked too.
    static func kinfo(_ pid: Int32) -> kinfo_proc? {
        guard pid > 0 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info
    }

    static func parentPID(_ pid: Int32) -> Int32? {
        kinfo(pid)?.kp_eproc.e_ppid
    }

    /// When the process started: of a multiplexer's clients the newest is
    /// taken, and a recycled pid is told apart by it (`Platform`).
    static func startedAt(_ pid: Int32) -> Date? {
        guard let info = kinfo(pid) else { return nil }
        let time = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000)
    }

    /// `proc_pidpath` fails (`ENOENT`) once the file the process was started
    /// from has been replaced — an app that updated itself under a running
    /// helper, as Orca's pty server was on this machine. The path it was
    /// started with is still in its argument area (`KERN_PROCARGS2`), which
    /// is also readable without a permission for the user's own processes.
    static func executablePath(_ pid: Int32) -> String? {
        guard pid > 0 else { return nil }
        // PROC_PIDPATHINFO_MAXSIZE (4 * MAXPATHLEN) is a macro Swift does not import.
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 { return String(cString: buffer) }
        return launchPath(pid)
    }

    /// The executable path at the head of `KERN_PROCARGS2`: an `argc`, then
    /// the path the process was exec'd with.
    static func launchPath(_ pid: Int32) -> String? {
        guard let buffer = procArgs(pid) else { return nil }
        let start = MemoryLayout<Int32>.size
        let end = buffer[start...].firstIndex(of: 0) ?? buffer.endIndex
        let path = String(decoding: buffer[start..<end], as: UTF8.self)
        return path.hasPrefix("/") ? path : nil
    }

    /// The environment the process was `exec`'d with (`KERN_PROCARGS2`, the
    /// same area as `launchPath`): what the agent inherited from its
    /// terminal, not what it set since — which is what a tab link is.
    static func environment(_ pid: Int32) -> [String] {
        procArgs(pid).map(environment(procArgs:)) ?? []
    }

    /// The arguments the process was `exec`'d with, from the same area.
    static func arguments(_ pid: Int32) -> [String] {
        procArgs(pid).map(arguments(procArgs:)) ?? []
    }

    /// Every pid, from `proc_listallpids`. The count can grow between the
    /// sizing call and the read, so the buffer has room to spare.
    static func allPIDs() -> [Int32] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(count) + 64)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        guard filled > 0 else { return [] }
        return pids.prefix(Int(filled)).filter { $0 > 0 }
    }

    /// The process's unix sockets (`PROC_PIDFDSOCKETINFO`), readable without
    /// a permission for the user's own processes. `nil` when the descriptor
    /// list cannot be read at all.
    static func unixSockets(_ pid: Int32) -> [UnixSocket]? {
        guard pid > 0 else { return nil }
        let stride = MemoryLayout<proc_fdinfo>.stride
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return nil }
        // Room for descriptors opened between the sizing call and the read.
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / stride + 16)
        let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * stride))
        guard filled > 0 else { return nil }
        return fds.prefix(Int(filled) / stride).compactMap { fd -> UnixSocket? in
            guard fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) else { return nil }
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size,
                  info.psi.soi_kind == Int32(SOCKINFO_UN) else { return nil }
            let un = info.psi.soi_proto.pri_un
            var address = un.unsi_addr.ua_sun
            let path = withUnsafeBytes(of: &address.sun_path) { bytes in
                String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            }
            return UnixSocket(pcb: info.psi.soi_pcb, peer: un.unsi_conn_pcb, path: path.isEmpty ? nil : path)
        }
    }

    /// Whether the process has a controlling terminal (`e_tdev` is not
    /// `NODEV`); `nil` when it cannot be read.
    static func hasTerminal(_ pid: Int32) -> Bool? {
        kinfo(pid).map { $0.kp_eproc.e_tdev != -1 }
    }

    /// `KERN_PROCARGS2`, whole: an `argc`, the executable path, NUL padding,
    /// `argc` arguments, then the environment up to an empty string.
    static func procArgs(_ pid: Int32) -> [UInt8]? {
        guard pid > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        return Array(buffer[..<size])
    }

    /// The environment in a `KERN_PROCARGS2` buffer. Pure; a short or
    /// truncated buffer gives what it holds, never reads past it.
    static func environment(procArgs buffer: [UInt8]) -> [String] {
        split(procArgs: buffer).environment
    }

    /// The arguments in a `KERN_PROCARGS2` buffer, as `environment` reads it.
    static func arguments(procArgs buffer: [UInt8]) -> [String] {
        split(procArgs: buffer).arguments
    }

    private static func split(procArgs buffer: [UInt8]) -> (arguments: [String], environment: [String]) {
        let head = MemoryLayout<Int32>.size
        guard buffer.count > head else { return ([], []) }
        let argc = buffer[0..<head].enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
        var index = buffer[head...].firstIndex(of: 0) ?? buffer.endIndex
        while index < buffer.endIndex, buffer[index] == 0 { index += 1 }
        var arguments: [String] = []
        var environment: [String] = []
        while index < buffer.endIndex {
            let end = buffer[index...].firstIndex(of: 0) ?? buffer.endIndex
            let string = String(decoding: buffer[index..<end], as: UTF8.self)
            // An empty argument is one (`claude --flag ""`); an empty string
            // after the arguments ends the environment.
            if arguments.count < argc {
                arguments.append(string)
            } else if end == index {
                break
            } else {
                environment.append(string)
            }
            index = end + 1
        }
        return (arguments, environment)
    }

    static func regularApp(_ pid: Int32) -> App? {
        guard pid > 0, let running = NSRunningApplication(processIdentifier: pid) else { return nil }
        return app(running)
    }

    static func runningApp(_ bundleID: String) -> App? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .lazy.compactMap(app).first
    }

    private static func app(_ running: NSRunningApplication) -> App? {
        guard running.activationPolicy == .regular, !running.isTerminated,
              let id = running.bundleIdentifier else { return nil }
        return App(bundleID: id, name: running.localizedName ?? id, pid: running.processIdentifier)
    }

    /// A bundle with no window to bring forward (`LSUIElement`,
    /// `LSBackgroundOnly`) is nobody's terminal: it is skipped rather than
    /// reported "closed". The case seen live was a session whose parent was
    /// another `claude` started from `ClaudeCode.app`, parented to launchd.
    static func bundle(_ path: String) -> (bundleID: String, name: String)? {
        guard let bundle = Bundle(path: path), let id = bundle.bundleIdentifier else { return nil }
        let plist = bundle.infoDictionary ?? [:]
        if plist["LSUIElement"] as? Bool == true || plist["LSBackgroundOnly"] as? Bool == true {
            return nil
        }
        let info = bundle.localizedInfoDictionary ?? [:]
        let name = (info["CFBundleDisplayName"] as? String)
            ?? (bundle.infoDictionary?["CFBundleDisplayName"] as? String)
            ?? (bundle.infoDictionary?["CFBundleName"] as? String)
            ?? ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        return (id, name)
    }

    /// A variable's value as `getenv` reads it: the first occurrence wins.
    static func value(_ name: String, in environment: [String]) -> String? {
        let prefix = name + "="
        return environment.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }
}
