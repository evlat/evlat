import XCTest
import AppKit
import SwiftUI
@testable import EvlatApp

/// Panelin **yapılandırması** kodla sınanır, gözle değil.
///
/// Ayrım bilinçli: "odak çalmıyor" iddiasının makineyle doğrulanabilen yarısı
/// bu dosyadadır (`canBecomeKey`, `styleMask`, `level`, `collectionBehavior`).
/// Uçtan uca yarısı — bara gerçekten tıklayınca öndeki uygulamanın odağını
/// koruması — kullanıcıya kalır ve sentetik tıkla taklit EDİLMEZ: `CGEvent`
/// Erişilebilirlik izni ister, izin gerektirmeyen tasarım projenin sözleşmesi.
@MainActor
final class PanelConfigTests: XCTestCase {
    /// `NSApp` test paketinde **nil**'dir: örtük açılan bir global ve
    /// `NSApplication.shared`'a dokunulana kadar kurulmuyor (ölçüldü — sinyal 5
    /// ile düşüyordu). Paneller de bir uygulama nesnesi olmadan kurulmamalı.
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    private func makePanel(edge: BarPanel.Edge = .right) -> BarPanel {
        BarPanel(edge: edge, size: CGSize(width: 56, height: 220), content: EmptyView())
    }

    func testPanelNeverTakesFocus() {
        let panel = makePanel()
        XCTAssertFalse(panel.canBecomeKey, "Bara tıklamak klavye odağını almamalı")
        XCTAssertFalse(panel.canBecomeMain, "Bar ana pencere olamaz")
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel),
                      "nonactivatingPanel olmadan tık uygulamayı öne getirir")
        XCTAssertTrue(panel.styleMask.contains(.borderless))
    }

    func testPanelFloatsAboveAndFollowsSpaces() {
        let panel = makePanel()
        XCTAssertEqual(panel.level, .statusBar,
                       "Bar sistem şeridi gibi davranır; v1'in .floating'i maskot içindi")
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces),
                      "Her space'te görünmeli")
        XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary),
                      "Tam ekran uygulamanın üstünde de durmalı")
        XCTAssertTrue(panel.collectionBehavior.contains(.stationary))
        XCTAssertFalse(panel.hidesOnDeactivate,
                       "Evlat arka plana düşünce bar kaybolmamalı")
    }

    func testPanelIsTransparent() {
        let panel = makePanel()
        XCTAssertFalse(panel.isOpaque)
        XCTAssertEqual(panel.backgroundColor, .clear)
        XCTAssertFalse(panel.hasShadow)
    }

    /// Pencere boyunun tek sahibi `BarPanel`. Varsayılan `sizingOptions` ile
    /// `NSHostingView` pencereyi içerik boyuna kendi getiriyor ve AppKit bunu
    /// sol üst köşe sabit yapıyor (v1'de ölçüldü). Hover'da sola açılan bar
    /// aynı duvara çarpar.
    func testHostingViewDoesNotResizeTheWindow() throws {
        let panel = makePanel()
        let hosting = try XCTUnwrap(panel.contentView as? NSHostingView<AnyView>)
        XCTAssertEqual(hosting.sizingOptions, [])
    }

    func testRightEdgePanelSitsOnTheUsableRightEdge() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let panel = makePanel(edge: .right)
        panel.reposition(on: screen)
        XCTAssertEqual(panel.frame.maxX, screen.visibleFrame.maxX, accuracy: 0.5,
                       "Sağ kenar Dock'un üstüne yaslanır (visibleFrame)")
        // Ortalama tam frame'den okunur: visibleFrame'den okunsaydı Dock gelip
        // gittiğinde bar dikeyde kayardı.
        XCTAssertEqual(panel.frame.midY, screen.frame.midY, accuracy: 0.5)
    }

    func testAccessoryPolicyKeepsItOutOfTheDock() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        XCTAssertEqual(app.activationPolicy(), .accessory,
                       "Dock ikonu ve Cmd-Tab girişi olmamalı")
    }

    /// Paneli öne getirmek uygulamayı etkinleştirmemeli. `orderFrontRegardless`
    /// tam olarak bunun için var; `makeKeyAndOrderFront` olsaydı Evlat öne gelirdi.
    func testShowingThePanelDoesNotActivateTheApp() {
        let app = NSApplication.shared
        let wasActive = app.isActive
        let panel = makePanel()
        panel.show()
        XCTAssertEqual(app.isActive, wasActive,
                       "Barı göstermek uygulamanın etkinlik durumunu değiştirmemeli")
        XCTAssertTrue(panel.isVisible)
        panel.close()
    }
}
