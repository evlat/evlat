import Foundation

/// Çekirdeğin dışarıdan aldığı platform yetenekleri.
///
/// `EvlatCore` Darwin çağırmaz — `sysctl`, `kill`, `open` burada değil,
/// `EvlatApp` tarafında yaşar ve buraya kapanışla verilir. Gerekçe: macOS'ta
/// `Foundation` Darwin'i yeniden ihraç ettiği için "yalnız Foundation import
/// et" kuralı taşınabilirliği **ölçmez**; v1'in `SessionHost.swift`'i tek
/// başına `Foundation` import edip `sysctl` kullanıyor ve Linux'ta derlenmez.
/// Enjeksiyon deseni v1'in kendi çözümü (`SessionStore.resolveHost`).
///
/// Varsayılanlar **saf ve güvenli**: gerçek yetenek bağlanmadıysa çekirdek
/// "bilmiyorum" der, tahmin etmez.
public struct Platform {
    /// Bu PID'de yaşayan bir süreç var mı? Varsayılan `false`: canlılık
    /// bilinmiyorsa oturum **ölü** sayılır, hayalet kayıt listede durmaz.
    public var isAlive: (Int32) -> Bool

    /// Bu PID'deki sürecin başlangıç zamanı. `nil` = süreç yok ya da okunamadı.
    ///
    /// Canlılık tek başına yetmiyor: macOS PID'leri **geri dönüştürür** ve
    /// oturum kayıtları aylarca duruyor (bu makinede Temmuz'dan kalma dosyalar
    /// var). Geri dönüşmüş bir PID'de bambaşka bir süreç yaşar ve kayıt
    /// hayalet bir oturum gösterir. Kayıt kendi başlangıç zamanını taşıdığı
    /// için ikisi karşılaştırılabilir.
    public var processStartedAt: (Int32) -> Date?

    /// Şimdi. Sınama sabit zaman verebilsin diye enjekte; `Date()` çağrısı
    /// koda dağılırsa zamana bağlı kural sınanamaz hâle gelir.
    public var now: () -> Date

    public init(isAlive: @escaping (Int32) -> Bool = { _ in false },
                processStartedAt: @escaping (Int32) -> Date? = { _ in nil },
                now: @escaping () -> Date = Date.init) {
        self.isAlive = isAlive
        self.processStartedAt = processStartedAt
        self.now = now
    }

    /// Hiçbir şey bilmeyen platform; sınamaların ve derleme zamanının varsayılanı.
    public static let unknown = Platform()
}
