import AppKit
import SwiftUI

/// Ekranın kenarına yaslanan, odak çalmayan bar penceresi.
///
/// Gövdesi v1'in `PetWindow`'undan portlandı; oradaki her ayarın bir sebebi
/// vardı ve sebepleri burada da geçerli. Tek bilinçli fark `level`:
/// v1 `.floating` kullanır, çünkü maskot ekranın köşesinde duran bir figürdü
/// ve menüleri örtmemesi gerekiyordu. Bar bir **sistem şeridi** gibi davranır,
/// o yüzden bir seviye yukarı çıkar.
public final class BarPanel: NSPanel {
    /// Barın yaslandığı kenar. Bugün yalnız `right` kullanılıyor; dördünü tek
    /// kodla çizen geometri soyutlaması 003'ün işi.
    public enum Edge: Sendable { case right, left, top, bottom }

    public let edge: Edge

    public init(edge: Edge = .right, size: CGSize, content: some View) {
        self.edge = edge
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   // .nonactivatingPanel: bara tıklayınca Evlat öne gelmez ve
                   // kullanıcının terminali odağını korur. Bu bar için
                   // pazarlık konusu değil — odak çalan bir şerit ürünü bitirir.
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)

        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // Evlat arka plana düştüğünde bar kaybolmamalı: sürekli görünür olmak
        // işinin tanımı.
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        titleVisibility = .hidden

        let hosting = NSHostingView(rootView: AnyView(content))
        // Pencere boyunun tek sahibi bu sınıf. Varsayılan sizingOptions ile
        // NSHostingView pencereyi içerik boyuna kendisi getiriyor ve AppKit
        // bunu SOL ÜST köşe sabit yapıyor — v1'de ölçüldü (taban 96→51, tepe
        // yerinde). Hover'da sola açılan bar aynı duvara çarpar.
        hosting.sizingOptions = []
        contentView = hosting

        reposition()
    }

    /// Odak asla bu pencereye geçmez. `.nonactivatingPanel` tek başına
    /// yetmiyor; `canBecomeKey` açık kalırsa panel klavye odağını alabiliyor.
    public override var canBecomeKey: Bool { false }
    public override var canBecomeMain: Bool { false }

    /// Yaslandığı eksende `visibleFrame` (Dock'un üstünde, menü çubuğunun
    /// altında), diğer eksende tam `frame`. İkinci yarısı bilinçli: ortalama
    /// `visibleFrame`den okunsaydı Dock gelip gittiğinde bar kayardı.
    public func reposition(on screen: NSScreen? = nil) {
        guard let screen = screen ?? self.screen ?? NSScreen.main else { return }
        let usable = screen.visibleFrame
        let full = screen.frame
        let size = frame.size
        let origin: NSPoint

        switch edge {
        case .right:
            origin = NSPoint(x: usable.maxX - size.width,
                             y: full.midY - size.height / 2)
        case .left:
            origin = NSPoint(x: usable.minX,
                             y: full.midY - size.height / 2)
        case .top:
            origin = NSPoint(x: full.midX - size.width / 2,
                             y: usable.maxY - size.height)
        case .bottom:
            origin = NSPoint(x: full.midX - size.width / 2,
                             y: usable.minY)
        }
        setFrameOrigin(origin)
    }

    /// `orderFront` değil: uygulama etkin olmadığında da görünmeli.
    public func show() {
        reposition()
        orderFrontRegardless()
    }
}
