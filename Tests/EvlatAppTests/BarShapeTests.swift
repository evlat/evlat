import XCTest
import SwiftUI
@testable import EvlatApp

/// Gövdenin geometrisi. Estetik gözle değerlendirilir ama **iki iddia
/// ölçülebilir** ve ikisi de sessizce bozulabilir: kenara yaslılık ve
/// uçlardaki ters kıvrımın yönü.
final class BarShapeTests: XCTestCase {
    private let rect = CGRect(x: 0, y: 0, width: 54, height: 260)

    /// Şekil ekran kenarına değer. Değmezse bar "yapıştırılmış" görünür.
    func testShapeTouchesTheScreenEdge() {
        let box = BarShape(edge: .right).path(in: rect).boundingRect
        XCTAssertEqual(box.maxX, rect.maxX, accuracy: 0.5, "sağ kenara yaslı")
    }

    /// Kenardaki dikey uzanım gövdeninkinden **uzundur**: flare çerçeveye
    /// doğru açılır. Şekil pencerenin tamamını kaplamalı.
    func testFlareReachesTheFullHeightAtTheEdge() {
        let path = BarShape(flare: 20, edge: .right).path(in: rect)
        XCTAssertEqual(path.boundingRect.minY, 0, accuracy: 0.5)
        XCTAssertEqual(path.boundingRect.maxY, rect.maxY, accuracy: 0.5)
    }

    /// Kıvrımın **yönü**: kenara yakın bir yükseklikte şekil dolu olmalı,
    /// gövdenin iç tarafında aynı yükseklikte boş. İlk sürümde eğri ters
    /// bükülüyordu ve bu sınama onu yakalar.
    func testFlareCurvesInwardNotOutward() {
        let flare = CGFloat(20)
        let path = BarShape(corner: 18, flare: flare, edge: .right).path(in: rect)
        // Eğri kenara **teğet** başlar: tepede flare daha 0.2pt genişliğinde
        // (çözüldü: x = w − flare·t², y = flare(2t − t²)). Ölçülecek yer
        // gövdenin üst kenarına yakın olan yer; orada genişlik ~yarım flare.
        let y = flare * 0.9
        XCTAssertTrue(path.contains(CGPoint(x: rect.maxX - 2, y: y)),
                      "kenarın dibinde, gövdenin üstünde flare dolu olmalı")
        XCTAssertFalse(path.contains(CGPoint(x: rect.maxX - 40, y: y)),
                       "gövdenin iç tarafında aynı yükseklik BOŞ olmalı — doluysa kıvrım ters")
        // Ve kıvrım gerçekten kenara sarılmalı: tepeye yakın yerde dolu alan
        // bir tık bile olsa var, ama gövde genişliğinin yarısına ulaşmamalı.
        XCTAssertFalse(path.contains(CGPoint(x: rect.maxX - rect.width / 2, y: 2)),
                       "tepede eğri kenara teğet; yarı genişliğe kadar dolmamalı")
    }

    /// Gövdenin ortası her zaman dolu.
    func testBodyIsFilled() {
        let path = BarShape(edge: .right).path(in: rect)
        XCTAssertTrue(path.contains(CGPoint(x: rect.midX, y: rect.midY)))
    }

    /// İç köşeler yuvarlak: gövdenin iç-üst köşe noktası boşta kalmalı.
    func testInnerCornersAreRounded() {
        let path = BarShape(corner: 18, flare: 20, edge: .right).path(in: rect)
        XCTAssertFalse(path.contains(CGPoint(x: 1, y: 21)),
                       "iç köşe yuvarlatılmış olmalı")
    }

    /// Sol kenar aynasıdır: aynı iddialar x ekseninde ters çalışır.
    func testLeftEdgeIsMirrored() {
        let path = BarShape(flare: 20, edge: .left).path(in: rect)
        XCTAssertEqual(path.boundingRect.minX, 0, accuracy: 0.5)
        XCTAssertTrue(path.contains(CGPoint(x: 2, y: 18)), "sol kenarın dibinde flare dolu")
        XCTAssertFalse(path.contains(CGPoint(x: 40, y: 18)))
    }

    /// Pencere çok kısaldığında şekil kendini yemez.
    func testDegenerateSizeDoesNotProduceAnEmptyOrInvertedPath() {
        for h in [CGFloat(8), 20, 41] {
            let small = CGRect(x: 0, y: 0, width: 54, height: h)
            let box = BarShape(corner: 18, flare: 20, edge: .right).path(in: small).boundingRect
            XCTAssertFalse(box.isEmpty, "h=\(h)")
            XCTAssertGreaterThan(box.width, 0, "h=\(h)")
            XCTAssertGreaterThan(box.height, 0, "h=\(h)")
        }
    }
}
