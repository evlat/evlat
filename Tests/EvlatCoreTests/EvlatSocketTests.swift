import XCTest
@testable import EvlatCore

/// Where Evlat's socket is: one rule for the app that binds it and every
/// client that posts to it.
final class EvlatSocketTests: XCTestCase {
    func testItIsUnderTheHome() {
        XCTAssertEqual(EvlatSocket.path(environment: [:], home: "/Users/a"),
                       "/Users/a/.config/evlat/run/evlat.sock")
        XCTAssertEqual(EvlatSocket.path(environment: ["EVLAT_HOME": "/tmp/h"], home: "/Users/a"),
                       "/tmp/h/.config/evlat/run/evlat.sock", "a home of its own moves it")
        XCTAssertEqual(EvlatSocket.path(environment: ["EVLAT_HOME": "  "], home: "/Users/a"),
                       "/Users/a/.config/evlat/run/evlat.sock", "a blank home is none")
        XCTAssertNil(EvlatSocket.path(environment: [:], home: nil))
    }

    /// `EVLAT_SOCKET` is the answer when set: an absolute path, or none —
    /// never the user's socket in its place.
    func testTheEnvironmentNamesIt() {
        XCTAssertEqual(EvlatSocket.path(environment: ["EVLAT_SOCKET": "/tmp/e/x.sock"], home: "/Users/a"),
                       "/tmp/e/x.sock")
        XCTAssertEqual(EvlatSocket.path(environment: ["EVLAT_SOCKET": "/tmp/e/x.sock", "EVLAT_PORT": "48999"],
                                        home: "/Users/a"), "/tmp/e/x.sock")
        XCTAssertNil(EvlatSocket.path(environment: ["EVLAT_SOCKET": "e/x.sock"], home: "/Users/a"))
    }

    /// An isolated process (`EVLAT_PORT`) without a socket of its own has
    /// none: a test or a measurement never takes the user's.
    func testAnIsolatedProcessHasNone() {
        XCTAssertNil(EvlatSocket.path(environment: ["EVLAT_PORT": "48999"], home: "/Users/a"))
        XCTAssertNil(EvlatSocket.path(environment: ["EVLAT_PORT": "48999", "EVLAT_HOME": "/tmp/h"], home: "/Users/a"))
    }

    /// A path no unix address holds is none: it could never be reached.
    func testAPathPastTheAddressIsNone() {
        let fits = "/" + String(repeating: "s", count: EvlatSocket.pathLimit - 1)
        XCTAssertEqual(EvlatSocket.path(environment: ["EVLAT_SOCKET": fits], home: nil), fits)
        XCTAssertNil(EvlatSocket.path(environment: ["EVLAT_SOCKET": fits + "s"], home: nil))
        let deep = "/" + String(repeating: "h", count: 90)
        XCTAssertNil(EvlatSocket.path(environment: [:], home: deep))
    }

    func testTheCurlWords() {
        XCTAssertEqual(EvlatSocket.Curl.socket("/Users/a b/x.sock"), "--unix-socket '/Users/a b/x.sock'")
        XCTAssertEqual(EvlatSocket.Curl.quoted("it's"), #"'it'\''s'"#)
        XCTAssertEqual(EvlatSocket.Curl.url("/hook"), "http://127.0.0.1:48151/hook")
        XCTAssertEqual(EvlatSocket.Curl.program, "curl -q")
        XCTAssertEqual(EvlatSocket.Curl.noProxy, "--noproxy '*'")
    }
}
