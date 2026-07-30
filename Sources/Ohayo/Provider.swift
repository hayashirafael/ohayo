import Foundation

/// O que difere entre os mundos Claude e Codex. Contas, detecção de janela,
/// identidade e execução roteiam por aqui.
enum Provider: String, Codable, CaseIterable {
    case claude, codex

    /// Duração do contrato de Janela de uso atualmente suportado pelo
    /// provedor. A propriedade vive no eixo de Provider para que detecção e
    /// recovery não dependam de uma constante global se os contratos
    /// divergirem no futuro.
    var usageWindowDuration: TimeInterval {
        switch self {
        case .claude, .codex: return 5 * 3600
        }
    }

    /// Infere o provider pelo CONTEÚDO da pasta (o nome é livre — `~/.claude2`,
    /// `~/claudio`, qualquer coisa). Precedência determinística: `.claude.json`
    /// → claude; senão `auth.json` → codex; senão `projects/` → claude; senão
    /// `sessions/` → codex; senão nil (pasta sem assinatura).
    static func detect(at dir: URL) -> Provider? {
        let fm = FileManager.default
        if fm.fileExists(atPath: dir.appendingPathComponent(".claude.json").path) {
            return .claude
        }
        if fm.fileExists(atPath: dir.appendingPathComponent("auth.json").path) {
            return .codex
        }
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: dir.appendingPathComponent("projects").path,
                         isDirectory: &isDir), isDir.boolValue {
            return .claude
        }
        if fm.fileExists(atPath: dir.appendingPathComponent("sessions").path,
                         isDirectory: &isDir), isDir.boolValue {
            return .codex
        }
        return nil
    }

    /// Subpasta com os transcripts JSONL usados na detecção de janela.
    var transcriptsSubpath: String {
        switch self {
        case .claude: return "projects"
        case .codex: return "sessions"
        }
    }

    /// Variável de ambiente que fixa a conta no subprocesso.
    var envKey: String {
        switch self {
        case .claude: return "CLAUDE_CONFIG_DIR"
        case .codex: return "CODEX_HOME"
        }
    }

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }

    /// Nome do binário no PATH.
    var cliName: String { rawValue }
}
