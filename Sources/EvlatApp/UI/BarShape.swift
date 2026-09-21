import SwiftUI

/// Barın gövdesi: kenara yaslanan, uçları **dışa** kıvrılan şekil.
///
/// Ayırt edici detay uçlardaki ters yuvarlatma (*flare*). Sıradan bir
/// yuvarlatılmış dikdörtgen ekranın üstüne **yapıştırılmış** görünür; burada
/// gövde kenara yaklaştıkça açılıp çerçeveye teğet biter, yani ekranın kendi
/// parçasıymış gibi okunur. Aynı hile macOS'un donanım çentiğinde ve
/// codenotch'un `SideNotchShape`'inde var.
///
/// Kenardaki dikey uzanım gövdeninkinden `2 × flare` kadar **uzundur**: şekil
/// çerçeveye doğru genişler.
///
/// ```
///        ┃  ← ekran kenarı
///     ╭──┚     üst flare: gövdeden kenara ters kıvrım
///     │  ┃
///     │  ┃  ← gövde, kenara yaslı
///     │  ┃
///     ╰──┒     alt flare
///        ┃
/// ```
public struct BarShape: Shape {
    /// Gövdenin iç köşelerinin (kenardan uzak taraf) yuvarlaklığı.
    public var corner: CGFloat
    /// Uçlardaki ters kıvrımın yarıçapı. Gövde bu kadar **kısalır**, kenardaki
    /// uzanım bu kadar **uzar**.
    public var flare: CGFloat
    /// Hangi kenara yaslı. Şekil sağ kenar için çizilir, ötekiler aynalanır.
    public var edge: BarPanel.Edge

    public init(corner: CGFloat = 20, flare: CGFloat = 14, edge: BarPanel.Edge = .right) {
        self.corner = corner
        self.flare = flare
        self.edge = edge
    }

    public func path(in rect: CGRect) -> Path {
        let path = canonicalPath(in: CGRect(origin: .zero, size: canonicalSize(of: rect)))
        return path.applying(transform(for: rect))
    }

    /// Dikey kenarlarda genişlik/yükseklik yer değiştirir: kanonik çizim her
    /// zaman "sağ kenar" içindir.
    private func canonicalSize(of rect: CGRect) -> CGSize {
        switch edge {
        case .right, .left: return rect.size
        case .top, .bottom: return CGSize(width: rect.height, height: rect.width)
        }
    }

    private func transform(for rect: CGRect) -> CGAffineTransform {
        switch edge {
        case .right:
            return .identity
        case .left:
            // x ekseninde aynala
            return CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -rect.width, y: 0)
        case .bottom:
            // Kanonik "sağ" → "alt": 90° döndür
            return CGAffineTransform(rotationAngle: -.pi / 2).translatedBy(x: -rect.height, y: 0)
        case .top:
            return CGAffineTransform(rotationAngle: .pi / 2).translatedBy(x: 0, y: -rect.width)
        }
    }

    /// Sağ kenar için çizim. Dolu bölge sağa yaslı; `w` ekranın kenarı.
    private func canonicalPath(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        // Flare gövdeden yer alır; pencere çok kısaldığında şekil kendini yemesin.
        let f = min(flare, h / 2)
        let c = min(corner, (h - 2 * f) / 2, w)
        let top = f            // gövdenin üst kenarı
        let bottom = h - f     // gövdenin alt kenarı

        var p = Path()
        // Kenarda, üst flare'in tepesi.
        p.move(to: CGPoint(x: w, y: 0))
        // Ters kıvrım: kenardan gövdenin üst kenarına.
        //
        // Kontrol noktası **kenar tarafındaki** köşede (w, top) durur. İlk
        // sürümde öteki köşeye (w-f, 0) konmuştu ve eğri ters bükülüyordu:
        // flare dışbükey çıkıp bara yapıştırılmış ikinci bir yuvarlak gibi
        // görünüyordu (ekran görüntüsüyle bakıldı). Kenar köşesi kontrol
        // olunca eğri kenara sarılır ve boşluk İÇERİ oyulur — çerçeveden
        // çıkıyor hissini veren şey bu.
        p.addQuadCurve(to: CGPoint(x: w - f, y: top),
                       control: CGPoint(x: w, y: top))
        // Gövdenin üst kenarı, iç köşeye kadar.
        p.addLine(to: CGPoint(x: c, y: top))
        // İç köşeler normal (dışbükey) yuvarlak.
        p.addQuadCurve(to: CGPoint(x: 0, y: top + c), control: CGPoint(x: 0, y: top))
        p.addLine(to: CGPoint(x: 0, y: bottom - c))
        p.addQuadCurve(to: CGPoint(x: c, y: bottom), control: CGPoint(x: 0, y: bottom))
        // Gövdenin alt kenarı ve alt flare.
        p.addLine(to: CGPoint(x: w - f, y: bottom))
        p.addQuadCurve(to: CGPoint(x: w, y: h), control: CGPoint(x: w, y: bottom))
        p.closeSubpath()
        return p
    }

    public var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(corner, flare) }
        set { corner = newValue.first; flare = newValue.second }
    }
}
