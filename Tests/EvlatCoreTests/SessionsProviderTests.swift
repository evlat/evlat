import XCTest
@testable import EvlatCore

/// `claude-sessions` sağlayıcısının sözleşmesi. Tamamı **başsız**: geçici
/// dizine fixture yazılır, canlılık sahte bir kapanışla verilir.
final class SessionsProviderTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("evlat-sessions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Alanlar gerçek bir kayıttan alındı (Claude Code 2.1.278).
    private func write(pid: Int32, sessionId: String, status: String,
                       name: String = "proje", cwd: String = "/tmp/proje",
                       updatedAt: Int = 1_790_000_000_000, extra: String = "") throws {
        let json = """
        {"pid":\(pid),"sessionId":"\(sessionId)","cwd":"\(cwd)","kind":"interactive",
         "name":"\(name)","nameSource":"derived","status":"\(status)",
         "updatedAt":\(updatedAt),"statusUpdatedAt":\(updatedAt)\(extra)}
        """
        try json.write(to: dir.appendingPathComponent("\(pid).json"), atomically: true, encoding: .utf8)
    }

    private func provider(alive: @escaping (Int32) -> Bool = { _ in true }) -> SessionsProvider {
        SessionsProvider(directory: dir, platform: Platform(isAlive: alive))
    }

    // MARK: - Vakalar

    func testReadsLiveSession() throws {
        try write(pid: 100, sessionId: "s-1", status: "busy", name: "evlat-v2")
        let signals = provider().currentSignals()
        XCTAssertEqual(signals.count, 1)
        XCTAssertEqual(signals[0].entity, "s-1")
        XCTAssertEqual(signals[0].phase, .working, "busy → working")
        XCTAssertEqual(signals[0].label, "evlat-v2")
        XCTAssertEqual(signals[0].fidelity, .derived, "format belgelenmemiş")
        XCTAssertEqual(signals[0].provider, SessionsProvider.id)
        XCTAssertNil(signals[0].progress, "oturumlar yüzde üretmez")
    }

    func testDeadPidIsDropped() throws {
        try write(pid: 100, sessionId: "canlı", status: "busy")
        try write(pid: 200, sessionId: "ölü", status: "busy")
        let signals = provider(alive: { $0 == 100 }).currentSignals()
        XCTAssertEqual(signals.map(\.entity), ["canlı"])
    }

    /// `claude --resume` başka bir terminalde PID'i değiştirir; aynı
    /// `sessionId` için iki dosya kalabilir. Canlı olan kazanır.
    func testSameSessionInTwoFilesCollapsesToOne_livePidWins() throws {
        try write(pid: 100, sessionId: "aynı", status: "idle", updatedAt: 1_790_000_000_000)
        try write(pid: 200, sessionId: "aynı", status: "busy", updatedAt: 1_790_000_000_001)
        let signals = provider(alive: { $0 == 100 }).currentSignals()
        XCTAssertEqual(signals.count, 1, "sessionId başına tek kayıt")
        XCTAssertEqual(signals[0].phase, .idle, "canlı PID kazanır, daha yeni olan değil")
    }

    /// İkisi de canlıysa en yeni `updatedAt` kazanır.
    func testSameSessionBothAlive_newestWins() throws {
        try write(pid: 100, sessionId: "aynı", status: "idle", updatedAt: 1_790_000_000_000)
        try write(pid: 200, sessionId: "aynı", status: "busy", updatedAt: 1_790_000_009_999)
        let signals = provider().currentSignals()
        XCTAssertEqual(signals.count, 1)
        XCTAssertEqual(signals[0].phase, .working)
    }

    func testBrokenJsonDropsOnlyItsOwnRecord() throws {
        try write(pid: 100, sessionId: "sağlam", status: "busy")
        try "{ bu json değil".write(to: dir.appendingPathComponent("200.json"),
                                    atomically: true, encoding: .utf8)
        let signals = provider().currentSignals()
        XCTAssertEqual(signals.map(\.entity), ["sağlam"], "bozuk kayıt ötekileri düşürmez")
    }

    /// `proje.md` tuzağı: tanınmayan `status` sessizce `idle`'a düşmez.
    /// Bu makinede gerçekten görülmüş bir değer: `shell`.
    func testUnknownStatusStaysVisible() throws {
        try write(pid: 100, sessionId: "s-1", status: "shell")
        let p = provider()
        let signals = p.currentSignals()
        XCTAssertEqual(signals.count, 1)
        XCTAssertEqual(signals[0].rawStatus, "shell", "kaynağın sözcüğü korunur")
        XCTAssertTrue(p.unrecognizedStatuses.contains("shell"),
                      "tanınmayan değer teşhiste görünür olmalı")
    }

    func testKnownStatusIsNotReportedAsUnrecognized() throws {
        try write(pid: 100, sessionId: "s-1", status: "idle")
        let p = provider()
        _ = p.currentSignals()
        XCTAssertTrue(p.unrecognizedStatuses.isEmpty)
    }

    func testStatusMapping() throws {
        for (status, phase) in [("busy", Phase.working), ("idle", .idle), ("waiting", .waiting)] {
            try write(pid: 100, sessionId: "s", status: status)
            XCTAssertEqual(provider().currentSignals().first?.phase, phase, "\(status)")
        }
    }

    func testMissingDirectoryYieldsNoSignals() {
        let p = SessionsProvider(directory: dir.appendingPathComponent("yok"),
                                 platform: Platform(isAlive: { _ in true }))
        XCTAssertEqual(p.currentSignals().count, 0, "dizin yoksa çökme değil, boş liste")
    }

    func testRegistryHasLiveAndOrdering() throws {
        try write(pid: 100, sessionId: "boş", status: "idle", updatedAt: 1_790_000_000_000)
        try write(pid: 200, sessionId: "çalışan", status: "busy", updatedAt: 1_790_000_000_001)
        let registry = Registry()
        registry.register(provider())
        XCTAssertTrue(registry.hasLive)
        XCTAssertEqual(registry.aggregate(), .working)
        XCTAssertEqual(registry.ordered().map(\.entity), ["çalışan", "boş"],
                       "çalışan boştanın üstünde")
    }

    func testEmptyDirectoryMeansNoLiveWork() {
        let registry = Registry()
        registry.register(provider())
        XCTAssertFalse(registry.hasLive, "canlı oturum yoksa maskot uykuya geçer")
        XCTAssertEqual(registry.aggregate(), .idle)
    }
}

// MARK: - PID geri dönüşümü

extension SessionsProviderTests {
    private func providerWithStart(_ start: @escaping (Int32) -> Date?) -> SessionsProvider {
        SessionsProvider(directory: dir,
                         platform: Platform(isAlive: { _ in true }, processStartedAt: start))
    }

    /// macOS PID'leri geri dönüştürür ve oturum kayıtları aylarca durur.
    /// O PID'de artık başka bir süreç yaşıyorsa kayıt hayalettir.
    func testRecycledPidIsNotTheSameSession() throws {
        let sessionStart = 1_790_000_000_000
        try write(pid: 100, sessionId: "hayalet", status: "busy",
                  extra: ",\"startedAt\":\(sessionStart)")
        // Aynı PID'de ÇOK sonra başlamış bir süreç var.
        let laterStart = Date(timeIntervalSince1970: Double(sessionStart) / 1000 + 86_400)
        XCTAssertTrue(providerWithStart({ _ in laterStart }).currentSignals().isEmpty,
                      "başlangıç zamanı tutmuyorsa oturum ölü sayılır")
    }

    func testMatchingStartTimeKeepsTheSession() throws {
        let sessionStart = 1_790_000_000_000
        try write(pid: 100, sessionId: "gerçek", status: "busy",
                  extra: ",\"startedAt\":\(sessionStart)")
        let same = Date(timeIntervalSince1970: Double(sessionStart) / 1000 + 3)  // tolerans içinde
        XCTAssertEqual(providerWithStart({ _ in same }).currentSignals().map(\.entity), ["gerçek"])
    }

    /// Başlangıç zamanı okunamıyorsa kayda güvenilir: taze bir kaydı
    /// okunamayan bir alan yüzünden düşürmek, hayalet göstermekten kötü.
    func testUnreadableStartTimeDoesNotDropTheSession() throws {
        try write(pid: 100, sessionId: "s", status: "busy", extra: ",\"startedAt\":1790000000000")
        XCTAssertEqual(providerWithStart({ _ in nil }).currentSignals().count, 1)
    }

    /// Kayıtta `startedAt` yoksa (eski format) karşılaştırma yapılmaz.
    func testRecordWithoutStartedAtIsKept() throws {
        try write(pid: 100, sessionId: "s", status: "busy")
        let far = Date(timeIntervalSince1970: 1)
        XCTAssertEqual(providerWithStart({ _ in far }).currentSignals().count, 1)
    }
}

// MARK: - Eksik alanlar (kapı bulguları)

extension SessionsProviderTests {
    private func writeRaw(_ name: String, _ json: String) throws {
        try json.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    /// Alanın **yokluğu** ile **tanınmayan değer** ayrı şeyler; alansız bir
    /// kayıt "bilinmeyen sözcük" diye bildirilmemeli.
    func testMissingStatusIsNotReportedAsUnrecognized() throws {
        try writeRaw("100.json", #"{"pid":100,"sessionId":"s","cwd":"/tmp","updatedAt":1790000000000}"#)
        let p = provider()
        let signals = p.currentSignals()
        XCTAssertEqual(signals.count, 1)
        XCTAssertNil(signals[0].rawStatus, "alan yoksa boş dizge değil, nil")
        XCTAssertTrue(p.unrecognizedStatuses.isEmpty, "yokluk, tanınmayan değer değildir")
        XCTAssertEqual(signals[0].phase, .idle)
    }

    func testBlankStatusIsTreatedAsMissing() throws {
        try writeRaw("100.json", #"{"pid":100,"sessionId":"s","status":"   ","updatedAt":1790000000000}"#)
        let p = provider()
        XCTAssertNil(p.currentSignals().first?.rawStatus)
        XCTAssertTrue(p.unrecognizedStatuses.isEmpty)
    }

    /// `updatedAt` okunamazsa 1970'e düşmez ve **görünür** olur; yoksa o kayıt
    /// her teklileştirme yarışını kaybeder ve 002'nin budaması onu siler.
    func testMissingUpdatedAtFallsBackAndIsVisible() throws {
        let started = 1_790_000_000_000
        try writeRaw("100.json",
                     #"{"pid":100,"sessionId":"s","status":"busy","startedAt":\#(started)}"#)
        let p = provider()
        let signals = p.currentSignals()
        XCTAssertEqual(signals.count, 1)
        XCTAssertEqual(signals[0].updatedAt.timeIntervalSince1970,
                       Double(started) / 1000, accuracy: 1,
                       "startedAt'e düşer, 1970'e değil")
        XCTAssertEqual(p.recordsMissingUpdatedAt, 1, "format kayması görünür olmalı")
    }

    func testMissingUpdatedAtAndStartedAtFallsBackToFileDate() throws {
        try writeRaw("100.json", #"{"pid":100,"sessionId":"s","status":"busy"}"#)
        let p = provider()
        let signal = try XCTUnwrap(p.currentSignals().first)
        XCTAssertGreaterThan(signal.updatedAt.timeIntervalSince1970, 1_700_000_000,
                             "dosyanın değiştirilme zamanına düşer")
        XCTAssertEqual(p.recordsMissingUpdatedAt, 1)
    }

    func testCounterResetsBetweenScans() throws {
        try writeRaw("100.json", #"{"pid":100,"sessionId":"s","status":"busy"}"#)
        let p = provider()
        _ = p.currentSignals()
        _ = p.currentSignals()
        XCTAssertEqual(p.recordsMissingUpdatedAt, 1, "sayaç her taramada sıfırlanır, birikmez")
    }
}
