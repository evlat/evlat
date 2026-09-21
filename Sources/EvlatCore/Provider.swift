import Foundation

/// Bir sinyal kaynağı. Kaynağa özgü her şey burada kalır; çekirdek kanonik
/// sözlüğü görür (v1'in `AgentSource.canonical` deseni).
///
/// Sağlayıcı **derlenmiş** bir tiptir; dışarıdan kod yüklenmez. Dışarıdan
/// implementasyonun yolu yerel API'ye sinyal göndermektir (`002`).
public protocol Provider {
    /// Tel kimliği: `Signal.provider` ve ileride `/hook/{id}`.
    var id: String { get }
    /// O andaki sinyaller. Çağıran ana kuyruktadır.
    func currentSignals() -> [Signal]
}
