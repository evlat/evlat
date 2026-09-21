import Foundation

/// Bir kaynağın anlattığı tek bir durum. Uygulama "AI oturumu" bilmez,
/// `Signal` bilir: oturum takibi bu soyutlamanın ilk sağlayıcısıdır, tek
/// sağlayıcısı değil (ROADMAP → Dikiş).
public struct Signal: Equatable {
    public let provider: String
    /// Sağlayıcı içinde tekil kimlik. Oturumlarda `sessionId`.
    public let entity: String
    public let kind: Kind
    public let phase: Phase
    /// 0…1. Oturumlar üretmez; dolgulu halka ancak veren bir sağlayıcıyla doğar.
    public let progress: Double?
    /// Kısa ad — listede görünen.
    public let label: String
    public let detail: String?
    public let fidelity: Fidelity
    /// Kaynağın kendi sözcüğü, çevrilmeden. Tanınmayan bir değer buradan
    /// **görünür** olur; `phase` onu sessizce yutmasın diye duruyor.
    public let rawStatus: String?
    public let updatedAt: Date

    public init(provider: String, entity: String, kind: Kind = .session,
                phase: Phase, progress: Double? = nil, label: String,
                detail: String? = nil, fidelity: Fidelity,
                rawStatus: String? = nil, updatedAt: Date) {
        self.provider = provider
        self.entity = entity
        self.kind = kind
        self.phase = phase
        self.progress = progress
        self.label = label
        self.detail = detail
        self.fidelity = fidelity
        self.rawStatus = rawStatus
        self.updatedAt = updatedAt
    }

    public enum Kind: String, Equatable { case session, usage, job, custom }

    /// Sayının ne kadar sağlam olduğu (codenotch'un `Fidelity`'si). UI bir
    /// tahmini, yayımlanmış veri gibi göstermez.
    public enum Fidelity: String, Equatable {
        /// Kaynağın kendi belgelenmiş çıktısı.
        case official
        /// Evlat'ın türettiği ya da belgelenmemiş bir formattan okuduğu.
        case derived
        /// Kullanıcının elle girdiği.
        case manual
    }
}

/// Durum makinesi. v1'in beş değeri aynen taşınır (`SessionStore.Phase`).
///
/// **Altıncı bir değer eklenmedi** ve bu bilinçli: her yeni değer maskotun
/// ifade tablosunu, barın gösterge dilini ve `Aggregator` önceliğini birden
/// değiştirir. Tanınmayan bir kaynak sözcüğü `Signal.rawStatus`'ta görünür
/// kalır, `Phase`i kirletmez. "Canlı oturum var mı" da bir faz değil,
/// `Registry.hasLive` sorusudur.
public enum Phase: String, CaseIterable, Equatable {
    case idle, working, waiting, review, failed

    /// Maskotun tek yüzü var, N oturum var: hangisi kazanır.
    /// Kullanıcıyı bekleten bir şey her zaman öne çıkar.
    public var priority: Int {
        switch self {
        case .failed: return 4
        case .waiting: return 3
        case .working: return 2
        case .review: return 1
        case .idle: return 0
        }
    }
}
