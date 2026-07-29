/// Resultado de domínio de um disparo. Diferencia conclusão, hand-off e
/// bloqueios permanentes de falhas transitórias que a agenda deve tentar de
/// novo. O histórico (`FireResult`) continua descrevendo o que foi observado
/// para a pessoa; este tipo orienta os motores.
enum DispatchOutcome: Equatable {
    case completed
    case launched
    case skipped
    case paused
    case retryableFailure
    case needsAttention

    /// Somente falhas transitórias preservam a ocorrência para retry.
    /// Autenticação, CLI e permissões exigem ação humana e não podem entrar em
    /// loop; os demais estados já consumiram o disparo.
    var advancesSchedule: Bool {
        self != .retryableFailure
    }
}
