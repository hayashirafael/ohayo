import Foundation

/// Estado mínimo durável de uma renovação contínua. Não persiste prompt,
/// credencial ou output; apenas o necessário para não duplicar hand-offs nem
/// perder retry/bloqueio quando o app reinicia.
enum RenewalRecoveryState: Codable, Equatable {
    case cooldown(notBefore: Date, bootstrapOrigin: Bool)
    case retry(notBefore: Date, attempt: Int, bootstrapOrigin: Bool)
    case needsAttention(bootstrapOrigin: Bool)

    var bootstrapOrigin: Bool {
        switch self {
        case .cooldown(_, let bootstrapOrigin),
             .retry(_, _, let bootstrapOrigin),
             .needsAttention(let bootstrapOrigin):
            return bootstrapOrigin
        }
    }
}
