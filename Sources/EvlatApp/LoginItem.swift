import Foundation
import ServiceManagement
import EvlatCore

/// "Open at login" (`014`, R5): `SMAppService.mainApp`, the only place
/// `ServiceManagement` is imported.
///
/// The registration belongs to the bundle id, not the path (context →
/// Kanıt, measured): v1, `build/Evlat.app` and `/Applications/Evlat.app`
/// all see — and can take away — the same item. Which copy macOS opens at
/// login was not measured (it needs a login) and stays a hand check.
///
/// The service is handed in, like `defaults`: only `launch()` passes the
/// real one (`service(environment:)`), and not even it in an isolated
/// launch. A test never registers anything.
struct LoginItem {
    enum Status: Equatable {
        case on, off
        /// Registered, but the user has to allow it in System Settings.
        case needsApproval
    }

    /// What the item is made of, as closures: the real one wraps
    /// `SMAppService`, a test's records.
    struct Service {
        var status: () -> Status
        var register: () throws -> Void
        var unregister: () throws -> Void
    }

    let service: Service

    var status: Status { service.status() }

    /// Turns it on or off. Asking for what is already there writes nothing.
    func set(_ on: Bool) throws {
        switch (on, status) {
        case (true, .on), (false, .off): return
        case (true, _): try service.register()
        case (false, _): try service.unregister()
        }
    }

    /// `notFound` is off: an app never registered reads it (measured).
    static func status(_ status: SMAppService.Status) -> Status {
        switch status {
        case .enabled: return .on
        case .requiresApproval: return .needsApproval
        case .notRegistered, .notFound: return .off
        @unknown default: return .off
        }
    }

    static let mainApp = Service(
        status: { status(SMAppService.mainApp.status) },
        register: { try SMAppService.mainApp.register() },
        unregister: { try SMAppService.mainApp.unregister() })

    /// Kept in memory: what an isolated launch gets, so a measurement never
    /// adds or removes the user's login item.
    static func inMemory(_ initial: Status = .off) -> Service {
        final class Box { var status: Status; init(_ s: Status) { status = s } }
        let box = Box(initial)
        return Service(status: { box.status },
                       register: { box.status = .on },
                       unregister: { box.status = .off })
    }

    /// The real service unless the process is isolated (`Isolation`).
    static func service(environment: [String: String], real: Service = mainApp) -> Service {
        Isolation.isIsolated(environment) ? inMemory() : real
    }
}
