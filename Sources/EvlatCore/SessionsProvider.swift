import Foundation

/// Claude Code'un kendi oturum kayıtlarını okur: `~/.claude/sessions/<pid>.json`.
///
/// **Bu sağlayıcı hook'ların yerine geçmez, onları tamamlar.** Durumun kaynağı
/// hook'lardır (v1'de öyleydi, v2'de de öyle); buradan gelen `status` kaba ve
/// "seni bekliyor" ayrımını taşımıyor. Bu dosyanın kaldırdığı şey v1'in üç
/// workaround'u:
///   - hook'lar yalnız kurulumdan SONRA açılan oturumlarda çalışır; burada
///     var olan bütün oturumlar anında görünür,
///   - `kill -9`'lanan oturum `Stop` göndermez; PID canlılığı ölüyü eler,
///   - oturum adı için alt süreç koşuyordu (`claude agents --json`); `name`
///     burada hazır.
///
/// **Format belgelenmemiştir** (`peerProtocol: 1` sürümlü bir şey ima ediyor),
/// o yüzden `Fidelity` `.derived` ve tanınmayan `status` değerleri
/// `unrecognizedStatuses`'ta görünür kalır.
public final class SessionsProvider: Provider {
    public static let id = "claude-sessions"
    public var id: String { Self.id }

    private let directory: URL
    private let platform: Platform
    /// Tanınmayan `status` değerleri. Sessizce `idle`'a düşmesin diye
    /// biriktirilir; teşhis buradan okunur (`proje.md` → tuzaklar).
    public private(set) var unrecognizedStatuses: Set<String> = []
    /// `updatedAt` alanı okunamayan kayıt sayısı. Sıfırdan farklıysa format
    /// kaymış olabilir; tanınmayan `status` gibi bu da **görünür** kalmalı.
    public private(set) var recordsMissingUpdatedAt = 0

    public init(directory: URL, platform: Platform) {
        self.directory = directory
        self.platform = platform
    }

    /// Varsayılan yer. Sabit yazılmaz, çağıranın verdiği yol kazanır —
    /// sınama geçici dizin verebilsin diye.
    public static func defaultDirectory(home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> URL {
        home.appendingPathComponent(".claude/sessions")
    }

    public func currentSignals() -> [Signal] {
        // Dizin yoksa bu bir hata değil: Claude Code hiç çalışmamış olabilir.
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []

        recordsMissingUpdatedAt = 0
        var best: [String: Record] = [:]
        for file in files where file.pathExtension == "json" {
            guard let record = Record(file: file) else { continue }   // bozuk kayıt ötekileri düşürmez
            guard isTheSameProcess(record) else { continue }
            // `claude --resume` PID'i değiştirir; aynı sessionId iki dosyada
            // kalabilir. Burada ikisi de canlı, o yüzden en yeni kazanır.
            // (Ölü olan zaten yukarıda elendi: "canlı PID kazanır" kuralı.)
            if record.updatedAtWasMissing { recordsMissingUpdatedAt += 1 }
            if let existing = best[record.sessionId], existing.updatedAt >= record.updatedAt { continue }
            best[record.sessionId] = record
        }

        return best.values.map { record in
            // Alanın **yokluğu** ile **tanınmayan bir değer** ayrı şeyler.
            // İlk sürüm ikisini birleştiriyordu: alansız bir kayıt boş dizgeyi
            // "bilinmeyen sözcük" diye bildiriyordu (kapıda yakalandı).
            let phase = record.status.flatMap(Self.phase(for:))
            if let status = record.status, phase == nil { unrecognizedStatuses.insert(status) }
            return Signal(
                provider: Self.id,
                entity: record.sessionId,
                kind: .session,
                // Tanınmayan durum `idle` çizilir ama sözcüğü `rawStatus`'ta
                // durur ve `unrecognizedStatuses`'a düşer: görünmez olmaz.
                phase: phase ?? .idle,
                label: record.label,
                detail: record.cwd,
                fidelity: .derived,
                rawStatus: record.status,
                updatedAt: record.updatedAt
            )
        }
        .sorted { $0.entity < $1.entity }   // deterministik sıra; görünüm sırası Registry'nin işi
    }

    /// Kayıttaki PID'de **o oturumun** süreci mi yaşıyor?
    ///
    /// İki kapı: süreç var mı, ve **aynı süreç mi**. İkincisi PID geri dönüşümü
    /// içindir — kayıtlar aylarca duruyor, PID'ler yeniden dağıtılıyor ve
    /// yalnız `isAlive`'a bakan bir kontrol hayalet oturum gösterirdi.
    /// Başlangıç zamanı okunamıyorsa kayda güvenilir: taze bir kaydı
    /// okunamayan bir alan yüzünden düşürmek, hayalet göstermekten daha kötü.
    private func isTheSameProcess(_ record: Record) -> Bool {
        guard platform.isAlive(record.pid) else { return false }
        guard let actual = platform.processStartedAt(record.pid),
              let claimed = record.startedAt else { return true }
        // Saniye çözünürlüğü ve kaydın sürecin kendisinden bir tık sonra
        // yazılması için tolerans. Geri dönüşmüş bir PID'de fark günlerdir.
        return abs(actual.timeIntervalSince(claimed)) < 120
    }

    /// Kaynağın sözcüğünü kanonik faza çevirir. `nil` = tanımadık.
    /// Bu makinede ölçülen değerler: `busy`, `idle`, bir kez `shell`.
    /// `waiting` hiç görülmedi — o ayrım hook'lardan gelir.
    static func phase(for status: String) -> Phase? {
        switch status {
        case "busy": return .working
        case "idle": return .idle
        case "waiting": return .waiting
        default: return nil
        }
    }

    /// Dosyanın tipli görünümü. Yalnız gerekli alanlar okunur; format
    /// genişlerse buraya dokunmadan geçer.
    private struct Record {
        let pid: Int32
        let sessionId: String
        /// Yoksa `nil` — boş dizge değil; ikisi ayrı anlam taşıyor.
        let status: String?
        let cwd: String
        let name: String?
        let updatedAt: Date
        /// Oturumun (yani sürecin) başlangıcı; PID geri dönüşümünü ayırt eder.
        let startedAt: Date?
        /// `updatedAt` okunamadı ve yedeğe düşüldü. Format kaymasının işareti.
        let updatedAtWasMissing: Bool

        var label: String {
            if let name, !name.isEmpty { return name }
            let last = (cwd as NSString).lastPathComponent
            return last.isEmpty ? sessionId : last
        }

        init?(file: URL) {
            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = (json["pid"] as? NSNumber)?.int32Value,
                  let sessionId = json["sessionId"] as? String, !sessionId.isEmpty
            else { return nil }
            self.pid = pid
            self.sessionId = sessionId
            let rawStatus = (json["status"] as? String)?.trimmingCharacters(in: .whitespaces)
            self.status = (rawStatus?.isEmpty ?? true) ? nil : rawStatus
            self.cwd = json["cwd"] as? String ?? ""
            self.name = json["name"] as? String
            self.startedAt = (json["startedAt"] as? NSNumber)
                .map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
            // Milisaniye epoch. Alan yoksa **1970'e düşmez**: o kayıt her
            // teklileştirme yarışını kaybeder, listenin en dibine oturur ve
            // 002'nin bayat-kayıt budaması onu anında siler — yani belgelenmemiş
            // bir formatta alan adı değişirse hata sessizce görünmez olurdu.
            // Sıra: updatedAt → startedAt → dosyanın kendi değiştirilme zamanı.
            if let ms = (json["updatedAt"] as? NSNumber)?.doubleValue, ms > 0 {
                self.updatedAt = Date(timeIntervalSince1970: ms / 1000)
                self.updatedAtWasMissing = false
            } else {
                let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate
                self.updatedAt = startedAt ?? mtime ?? Date(timeIntervalSince1970: 0)
                self.updatedAtWasMissing = true
            }
        }
    }
}
