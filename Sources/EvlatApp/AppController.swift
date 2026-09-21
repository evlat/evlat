import AppKit
import SwiftUI
import EvlatCore

/// Uygulamanın kurulumu tek yerde. `main.swift` yalnız bunu çağırır, böylece
/// buradaki her şey sınanabilir kalır (yürütülebilir hedefin top-level kodu
/// sınamada çalıştırılamaz).
public final class AppController: NSObject, NSApplicationDelegate {
    public private(set) var panel: BarPanel?
    private var statusItem: NSStatusItem?

    /// Barın kapalı hâlinin ölçüleri. 003'te geometri soyutlaması gelince
    /// buradan çıkacak; bugün tek yerde sabit durması yeter.
    public static let collapsedSize = CGSize(width: 56, height: 220)

    /// Gerçek platform yetenekleri. Darwin'e dokunan tek yer burası;
    /// `EvlatCore` bunları kapanış olarak alır.
    public static var darwinPlatform: Platform {
        Platform(isAlive: Self.isProcessAlive)
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
        guard pid > 0 else { return false }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else {
            return false
        }
        return info.kp_proc.p_stat != SZOMB
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // .accessory: Dock'ta ikon yok, Cmd-Tab'da yok. Bar bir uygulama gibi
        // değil, sistemin parçası gibi davranmalı.
        NSApp.setActivationPolicy(.accessory)
        installStatusItem()

        let panel = BarPanel(edge: .right,
                             size: Self.collapsedSize,
                             content: PlaceholderBar())
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

/// Maskot gelene kadarki yer tutucu (phase-2 onu değiştirir).
struct PlaceholderBar: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(.black.opacity(0.85))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(.white.opacity(0.08), lineWidth: 1)
            )
            .padding(.vertical, 8)
            .padding(.trailing, -18)   // sağ kenarın yuvarlağı çerçevenin dışına taşsın
    }
}
