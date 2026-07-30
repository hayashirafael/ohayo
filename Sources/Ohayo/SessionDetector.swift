import CoreFoundation
import Foundation

/// Estado observado da janela de uso de uma Conta.
///
/// `inactive` significa que a leitura foi conclusiva e não encontrou Evidência
/// de Janela ativa. `unavailable` preserva falhas de acesso ou contratos de
/// transcript desconhecidos, sem convertê-los em ausência de uso.
enum QuotaWindowState: Equatable {
    case active(until: Date)
    case inactive
    case unavailable(reason: String)
}

protocol SessionDetecting {
    /// O provider é parte da identidade persistida da conta. Consumidores de
    /// produção devem passá-lo explicitamente em vez de reinferir pelo disco.
    func quotaWindowState(
        account: URL,
        provider: Provider
    ) async -> QuotaWindowState
}

extension SessionDetecting {
    /// Conveniência para testes e chamadas legadas. Fluxos de produção que já
    /// conhecem o provider usam a sobrecarga explícita acima.
    func quotaWindowState(account: URL) async -> QuotaWindowState {
        await quotaWindowState(
            account: account,
            provider: Provider.detect(at: account) ?? .claude
        )
    }

    /// Adapter temporário para consumidores existentes. `unavailable` não é
    /// rebaixado para `inactive` na API nova, embora ambos precisem resultar em
    /// nil enquanto os schedulers ainda dependem do contrato legado.
    ///
    /// `account` é a pasta da conta (`~/.claude`, `~/.codex`…); o detector
    /// deriva a subpasta de transcripts pelo provider.
    func activeWindowEnd(account: URL) async -> Date? {
        guard case .active(let end) = await quotaWindowState(account: account) else {
            return nil
        }
        return end
    }

    func activeWindowEnd(account: URL, provider: Provider) async -> Date? {
        guard case .active(let end) = await quotaWindowState(
            account: account,
            provider: provider
        ) else {
            return nil
        }
        return end
    }
}

/// Reconstrói a janela de 5h lendo passivamente os transcripts JSONL do
/// provedor. Só eventos com evidência positiva de tokens participam do cálculo;
/// falhas e eventos meramente locais não abrem uma janela. Nunca executa o CLI.
struct SessionDetector: SessionDetecting {
    var clock: Clock = SystemClock()

    private enum UsageLineResult {
        case evidence(Date)
        case noEvidence
        case unavailable(String)
    }

    private enum TokenUsageState {
        case positive
        case zero
        case unsupported
    }

    private enum TimestampCollection {
        case timestamps([Date])
        case unavailable(String)
    }

    private enum CandidateFileCollection {
        case files([URL])
        case unavailable(String)
    }

    /// 24h cobre cadeias de blocos consecutivos (o início do bloco corrente
    /// depende do fim do bloco anterior em uso contínuo).
    static let scanInterval: TimeInterval = 24 * 3600
    /// Compatibilidade para migrações e testes persistidos do contrato atual.
    /// Fluxos de produção usam `Provider.usageWindowDuration`.
    static let blockDuration = Provider.claude.usageWindowDuration

    func quotaWindowState(
        account: URL,
        provider: Provider
    ) async -> QuotaWindowState {
        let fm = FileManager.default
        let blockDuration = provider.usageWindowDuration
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: account.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                return .unavailable(reason: "account path is not a directory")
            }
            guard fm.isReadableFile(atPath: account.path) else {
                return .unavailable(reason: "account directory is not readable")
            }
        }
        let transcriptsDir = account.appendingPathComponent(provider.transcriptsSubpath)
        var lookback: TimeInterval = Self.scanInterval
        let maxLookback: TimeInterval = 7 * 24 * 3600
        while true {
            let since = clock.now.addingTimeInterval(-lookback)
            let collection = await collectTimestamps(
                projectsDir: transcriptsDir,
                provider: provider,
                since: since
            )
            let timestamps: [Date]
            switch collection {
            case .timestamps(let collected):
                timestamps = collected.sorted()
            case .unavailable(let reason):
                return .unavailable(reason: reason)
            }
            // Se o primeiro timestamp visível está a menos de 5h do início da
            // janela de varredura, a cadeia pode ter sido truncada no meio de
            // um bloco — amplia a varredura até garantir um gap de 5h à esquerda.
            if let first = timestamps.first,
               first.timeIntervalSince(since) < blockDuration,
               lookback < maxLookback {
                lookback = min(lookback * 2, maxLookback)
                continue
            }
            guard let end = Self.activeBlockEnd(
                timestamps: timestamps,
                now: clock.now,
                duration: blockDuration
            ) else {
                return .inactive
            }
            return .active(until: end)
        }
    }

    // MARK: - Núcleo puro (testável)

    /// Blocos de 5h: início = timestamp da primeira evidência de consumo;
    /// evidência após o fim do bloco corrente abre um bloco novo.
    static func activeBlockEnd(
        timestamps: [Date],
        now: Date,
        duration: TimeInterval = blockDuration
    ) -> Date? {
        var blockEnd: Date?
        for t in timestamps.sorted() {
            guard t <= now else { break }
            if blockEnd == nil || t >= blockEnd! {
                blockEnd = t.addingTimeInterval(duration)
            }
        }
        guard let end = blockEnd, now < end else { return nil }
        return end
    }

    /// Extrai somente o timestamp raiz do evento; timestamps aninhados em
    /// conteúdo de ferramentas não representam o momento do consumo.
    static func timestamp(fromLine line: String) -> Date? {
        guard let data = line.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return timestamp(fromRoot: root)
    }

    private static func timestamp(fromRoot root: [String: Any]) -> Date? {
        guard let raw = root["timestamp"] as? String else { return nil }
        return isoFractional.date(from: raw) ?? iso.date(from: raw)
    }

    private static func usageResult(
        fromLine line: String,
        provider: Provider
    ) -> UsageLineResult {
        switch provider {
        case .claude:
            guard let data = line.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .noEvidence
            }
            guard root["type"] as? String == "assistant" else {
                return .noEvidence
            }
            if root["isApiErrorMessage"] as? Bool == true {
                return .noEvidence
            }
            guard let rawMessage = root["message"],
                  let message = rawMessage as? [String: Any],
                  let model = message["model"] as? String else {
                return .unavailable("unsupported Claude assistant schema")
            }
            if model == "<synthetic>" {
                return .noEvidence
            }
            guard let usage = message["usage"] as? [String: Any] else {
                return .unavailable("unsupported Claude usage schema")
            }
            switch tokenUsageState(usage) {
            case .positive:
                guard let timestamp = timestamp(fromRoot: root) else {
                    return .unavailable("unsupported Claude usage schema")
                }
                return .evidence(timestamp)
            case .zero:
                return .noEvidence
            case .unsupported:
                return .unavailable("unsupported Claude usage schema")
            }
        case .codex:
            guard let data = line.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .noEvidence
            }
            guard root["type"] as? String == "event_msg",
                  let payload = root["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count" else {
                return .noEvidence
            }
            guard let rawInfo = payload["info"] else {
                return .unavailable("unsupported Codex usage schema")
            }
            // O Codex grava `info: null` antes de haver qualquer consumo. É um
            // estado conhecido e conclusivo, não uma quebra de schema.
            if rawInfo is NSNull {
                return .noEvidence
            }
            guard let info = rawInfo as? [String: Any],
                  let usage = info["last_token_usage"] as? [String: Any] else {
                return .unavailable("unsupported Codex usage schema")
            }
            switch tokenUsageState(usage) {
            case .positive:
                guard let timestamp = timestamp(fromRoot: root) else {
                    return .unavailable("unsupported Codex usage schema")
                }
                return .evidence(timestamp)
            case .zero:
                return .noEvidence
            case .unsupported:
                return .unavailable("unsupported Codex usage schema")
            }
        }
    }

    private static func tokenUsageState(_ usage: [String: Any]) -> TokenUsageState {
        var foundTokenField = false
        var foundPositiveValue = false
        for (key, value) in usage where key.hasSuffix("_tokens") {
            foundTokenField = true
            guard let number = value as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID() else {
                return .unsupported
            }
            if number.doubleValue > 0 {
                foundPositiveValue = true
            }
        }
        guard foundTokenField else { return .unsupported }
        return foundPositiveValue ? .positive : .zero
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let iso = ISO8601DateFormatter()

    // MARK: - Varredura

    private func candidateFiles(
        projectsDir: URL,
        since: Date
    ) -> CandidateFileCollection {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: projectsDir.path, isDirectory: &isDirectory) else {
            return .files([])
        }
        guard isDirectory.boolValue else {
            return .unavailable("transcript path is not a directory")
        }
        guard fm.isReadableFile(atPath: projectsDir.path) else {
            return .unavailable("transcript directory is not readable")
        }

        var enumerationFailed = false
        guard let enumerator = fm.enumerator(
            at: projectsDir,
            includingPropertiesForKeys: [
                .contentModificationDateKey,
                .isRegularFileKey,
            ],
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in
                enumerationFailed = true
                return false
            }
        ) else {
            return .unavailable("transcript directory is not enumerable")
        }
        var files: [URL] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            let values: URLResourceValues
            do {
                values = try url.resourceValues(
                    forKeys: [.contentModificationDateKey, .isRegularFileKey]
                )
            } catch {
                return .unavailable("transcript metadata is not readable")
            }
            guard values.isRegularFile == true,
                  fm.isReadableFile(atPath: url.path) else {
                return .unavailable("transcript file is not readable")
            }
            guard let mtime = values.contentModificationDate else {
                return .unavailable("transcript metadata is not readable")
            }
            guard mtime >= since else { continue }
            files.append(url)
        }
        guard !enumerationFailed else {
            return .unavailable("transcript directory is not enumerable")
        }
        return .files(files)
    }

    private func collectTimestamps(
        projectsDir: URL,
        provider: Provider,
        since: Date
    ) async -> TimestampCollection {
        var result: [Date] = []
        let candidates = candidateFiles(projectsDir: projectsDir, since: since)
        let files: [URL]
        switch candidates {
        case .files(let found):
            files = found
        case .unavailable(let reason):
            return .unavailable(reason)
        }
        for url in files {
            // Leitura mapeada + split síncrono, em vez de `url.lines` async: o
            // stream assíncrono tinha overhead por linha e por chamada; o
            // mapeamento (`.mappedIfSafe`) evita carregar arquivos grandes de
            // uma vez.
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  let text = String(data: data, encoding: .utf8) else {
                return .unavailable("transcript file is not readable")
            }
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                switch Self.usageResult(fromLine: String(line), provider: provider) {
                case .evidence(let timestamp):
                    if timestamp >= since { result.append(timestamp) }
                case .noEvidence:
                    continue
                case .unavailable(let reason):
                    return .unavailable(reason)
                }
            }
        }
        return .timestamps(result)
    }
}
