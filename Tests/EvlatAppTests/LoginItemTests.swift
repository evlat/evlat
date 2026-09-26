import XCTest
import ServiceManagement
@testable import EvlatApp

/// "Open at login" against an injected service: no test ever
/// registers the real app.
final class LoginItemTests: XCTestCase {
    private final class Recorder {
        var status: LoginItem.Status = .off
        var calls: [String] = []
        var service: LoginItem.Service {
            LoginItem.Service(status: { self.status },
                              register: { self.calls.append("register"); self.status = .on },
                              unregister: { self.calls.append("unregister"); self.status = .off })
        }
    }

    func testOnAndOffGoToTheService() throws {
        let recorder = Recorder()
        let item = LoginItem(service: recorder.service)
        XCTAssertEqual(item.status, .off)
        try item.set(true)
        XCTAssertEqual(item.status, .on)
        try item.set(true)
        try item.set(false)
        XCTAssertEqual(recorder.calls, ["register", "unregister"], "asking for what is there calls nothing")
        recorder.status = .needsApproval
        try item.set(false)
        XCTAssertEqual(recorder.calls.last, "unregister")
    }

    func testNotFoundIsOff() {
        XCTAssertEqual(LoginItem.status(.notFound), .off)
        XCTAssertEqual(LoginItem.status(.notRegistered), .off)
        XCTAssertEqual(LoginItem.status(.enabled), .on)
        XCTAssertEqual(LoginItem.status(.requiresApproval), .needsApproval)
    }

    func testAnIsolatedLaunchNeverReachesTheRealService() throws {
        let real = Recorder()
        for environment in [["EVLAT_PORT": "48999"], ["EVLAT_HOME": "/tmp/x"], ["EVLAT_FOO": ""]] {
            let item = LoginItem(service: LoginItem.service(environment: environment, real: real.service))
            try item.set(true)
            XCTAssertEqual(item.status, .on, "kept in memory")
        }
        XCTAssertEqual(real.calls, [])
        let item = LoginItem(service: LoginItem.service(environment: ["EVLAT_TASK": "t"], real: real.service))
        try item.set(true)
        XCTAssertEqual(real.calls, ["register"], "not isolated: the service handed in")
    }

    @MainActor
    func testTheControllerWithoutOneCallsNothing() {
        let controller = AppController(defaults: nil, home: nil)
        XCTAssertNil(controller.loginItem)
        controller.setLoginItem(on: true)
        XCTAssertFalse(controller.loginItemFailed)
    }
}
