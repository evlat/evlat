import AppKit
import SwiftUI
import EvlatCore

/// Uygulamanın kurulumu tek yerde. `main.swift` yalnız bunu çağırır, böylece
/// buradaki her şey sınanabilir kalır (yürütülebilir hedefin top-level kodu
/// sınamada çalıştırılamaz).
public final class AppController: NSObject, NSApplicationDelegate {
    public private(set) var panel: BarPanel?
    public let registry = Registry()
    private var statusItem: NSStatusItem?

    /// Barın kapalı hâlinin ölçüleri. 003'te geometri soyutlaması gelince
    /// buradan çıkacak; bugün tek yerde sabit durması yeter.
    public static let collapsedSize = CGSize(width: 54, height: 260)

    /// Gerçek platform yetenekleri. Darwin'e dokunan tek yer burası;
    /// `EvlatCore` bunları kapanış olarak alır.
    public static var darwinPlatform: Platform {
        Platform(isAlive: Self.isProcessAlive, processStartedAt: Self.processStartedAt)
    }

    /// Bu PID'de **gerçekten koşan** bir süreç var mı?
    ///
    /// `kill(pid, 0)` yetmiyor, iki yerden yanlış "canlı" diyor:
    ///   - `pid <= 0` özel anlamlı: `0` çağıranın kendi süreç grubu, `-1` her
    ///     süreç. Saklanmış ya da varsayılan bir `0` sonsuza dek canlı görünürdü.
    ///   - **Zombi**: çıkmış ama ebeveyni tarafından toplanmamış süreç hâlâ
    ///     tabloda; `kill` 0 döner, oysa oturum ölü.
    /// `sysctl`/`kinfo_proc` ikisini de çözüyor — `p_stat` zombiyi söylüyor.
    /// v1 de aynı yürüyüşü yapıyor (`SessionHost.parentPID`) ve izin istemiyor.
    static func isProcessAlive(_ pid: Int32) -> Bool {
        guard let info = procInfo(pid) else { return false }
        return info.kp_proc.p_stat != SZOMB
    }

    /// Sürecin başlangıç zamanı. PID geri dönüşümünü ayırt etmek için:
    /// kayıt kendi `startedAt`'ini taşıyor, ikisi tutmuyorsa o PID'de artık
    /// başka bir süreç yaşıyor demektir.
    static func processStartedAt(_ pid: Int32) -> Date? {
        guard let info = procInfo(pid) else { return nil }
        let tv = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000)
    }

    private static func procInfo(_ pid: Int32) -> kinfo_proc? {
        guard pid > 0 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        return info
    }

    /// Gerçek yerine bağlı sağlayıcı. Yol ve canlılık dışarıdan verilir;
    /// sınama ikisini de sahteleyebilir.
    public static func makeSessionsProvider() -> SessionsProvider {
        SessionsProvider(directory: SessionsProvider.defaultDirectory(),
                         platform: darwinPlatform)
    }

    /// `Evlat --liste`: sinyalleri yazdırıp çıkar. Pencere açmaz.
    /// v1'in `GET /status` teşhisinin bu setteki karşılığı; tam yerel API
    /// `002`'de geliyor.
    public static func printSignalsAndExit() -> Never {
        let provider = makeSessionsProvider()
        let registry = Registry()
        registry.register(provider)
        // Tek tarama, üç sayı. İlk sürüm `ordered()`, `aggregate()` ve
        // `hasLive`'ı ayrı ayrı çağırıyordu; üçü de dizini baştan okuduğu için
        // arada değişen bir dosya çelişkili bir özet bastırabiliyordu.
        let signals = registry.ordered()
        let aggregate = signals.map(\.phase).max(by: { $0.priority < $1.priority }) ?? .idle
        print("sağlayıcı: \(SessionsProvider.id)  ·  dizin: \(SessionsProvider.defaultDirectory().path)")
        print("canlı oturum: \(signals.count)  ·  toplu durum: \(aggregate.rawValue)  ·  hasLive: \(!signals.isEmpty)")
        for s in signals {
            let raw = s.rawStatus.map { " (raw: \($0))" } ?? ""
            print("  \(s.phase.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0)) \(s.label)\(raw)  ← \(s.detail ?? "")")
        }
        if !provider.unrecognizedStatuses.isEmpty {
            print("tanınmayan status: \(provider.unrecognizedStatuses.sorted().joined(separator: ", "))")
        }
        if provider.recordsMissingUpdatedAt > 0 {
            print("updatedAt okunamayan kayıt: \(provider.recordsMissingUpdatedAt) (format kaymış olabilir)")
        }
        exit(0)
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // .accessory: Dock'ta ikon yok, Cmd-Tab'da yok. Bar bir uygulama gibi
        // değil, sistemin parçası gibi davranmalı.
        NSApp.setActivationPolicy(.accessory)
        registry.register(Self.makeSessionsProvider())
        installStatusItem()

        let panel = BarPanel(edge: .right,
                             size: Self.collapsedSize,
                             content: BarBody(edge: .right))
        panel.show()
        self.panel = panel
    }

    /// Menü çubuğu girişi — bugün yalnız çıkış. Bar'ın kendi sağ tık menüsü
    /// ve ayarlar 003/004'ün işi.
    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "square.on.square",
                                     accessibilityDescription: "Evlat")
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Quit Evlat",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }
}

/// Barın gövdesi. İçerik (maskot, oturum göstergeleri) phase-2'de gelecek;
/// bugün yalnız şekil var.
struct BarBody: View {
    var edge: BarPanel.Edge = .right

    var body: some View {
        let shape = BarShape(corner: 18, flare: 20, edge: edge)
        shape
            .fill(Color.black.opacity(0.88))
            // İnce iç kenar: gövdeyi koyu bir duvardan ayırır ve flare'in
            // kıvrımını görünür kılar. Kenarın kendisinde çizgi olmamalı —
            // orası ekranın dışı.
            .overlay(shape.stroke(Color.white.opacity(0.10), lineWidth: 1))
            // Gölge kıvrımı derinleştirir; çerçeveden çıkıyor hissini o veriyor.
            .shadow(color: .black.opacity(0.35), radius: 10, x: -3, y: 0)
    }
}
