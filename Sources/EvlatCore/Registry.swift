import Foundation

/// Sağlayıcıların çıktısını toplar ve tek bir görünüme indirger.
///
/// **Zaman kaynaklı geçişler burada YOK.** v1'de var (`review`→`idle` 25 sn,
/// bayat kayıt budama); sahibi bu sınıf olacak ama `002`'nin işi. `Signal`
/// `updatedAt` taşıdığı için tip onları kaldırabilir.
public final class Registry {
    private var providers: [Provider] = []

    public init() {}

    public func register(_ provider: Provider) {
        providers.append(provider)
    }

    /// Bütün sağlayıcıların sinyalleri. Çakışma kuralı sağlayıcılar arasıdır
    /// ve `002`'de hook kazanacak; bugün tek sağlayıcı var, birleştirme yok.
    public func signals() -> [Signal] {
        providers.flatMap { $0.currentSignals() }
    }

    /// Maskotun yüzü. `Phase.priority`'nin en yükseği kazanır; hiç sinyal
    /// yoksa `idle`.
    public func aggregate() -> Phase {
        signals().map(\.phase).max(by: { $0.priority < $1.priority }) ?? .idle
    }

    /// Ekranda canlı bir şey var mı? **Bir faz değil**, bir görünüm koşulu:
    /// maskotun nefes/kırpma döngüsü buna bakar ve yanlışken view ağacından
    /// çıkar (ROADMAP → Render yolu, boşta çizim durur).
    public var hasLive: Bool { !signals().isEmpty }

    /// Listede gösterilecek sıra: bekleyenler tepede, sonra çalışanlar,
    /// sonra yeni bitenler, en altta boştalar. Eşitlikte en yeni önce.
    public func ordered() -> [Signal] {
        signals().sorted {
            $0.phase.priority != $1.phase.priority
                ? $0.phase.priority > $1.phase.priority
                : $0.updatedAt > $1.updatedAt
        }
    }
}
