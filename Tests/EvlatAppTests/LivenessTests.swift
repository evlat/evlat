import XCTest
@testable import EvlatApp

/// PID canlılığının kenar vakaları. `/code-review` phase-0'da `kill(pid, 0)`
/// tabanlı ilk sürümün iki yerden yanlış "canlı" dediğini buldu.
final class LivenessTests: XCTestCase {
    func testOwnProcessIsAlive() {
        XCTAssertTrue(AppController.isProcessAlive(ProcessInfo.processInfo.processIdentifier))
    }

    /// `kill(0, 0)` çağıranın kendi süreç grubunu hedefler ve 0 döner;
    /// `kill(-1, 0)` her süreci. İkisi de "bu oturum yaşıyor" demek değil.
    func testNonPositivePidsAreNotAlive() {
        XCTAssertFalse(AppController.isProcessAlive(0))
        XCTAssertFalse(AppController.isProcessAlive(-1))
        XCTAssertFalse(AppController.isProcessAlive(-999))
    }

    /// Kullanılmamış, çok büyük bir PID. macOS'ta PID'ler geri dönüşlü olduğu
    /// için "asla kullanılmaz" denemez; `PID_MAX`in (99999) üstü güvenli.
    func testImplausiblePidIsNotAlive() {
        XCTAssertFalse(AppController.isProcessAlive(999_999))
    }

    /// launchd her zaman koşar ve asla zombi olmaz.
    func testLaunchdIsAlive() {
        XCTAssertTrue(AppController.isProcessAlive(1))
    }
}
