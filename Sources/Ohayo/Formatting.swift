import Foundation

enum MarkdownResponseFormatter {
    static func attributedString(_ source: String) -> AttributedString {
        (try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .full)
        )) ?? AttributedString(source)
    }
}

@MainActor
enum Fmt {
    private enum Style: CaseIterable { case hhmm, dayTime, weekdayTime }
    private struct Key: Hashable { let language: AppLanguage; let style: Style }

    private static let formatters: [Key: DateFormatter] = {
        var result: [Key: DateFormatter] = [:]
        for language in AppLanguage.allCases {
            for style in Style.allCases {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: language.localeIdentifier)
                switch style {
                case .hhmm:
                    // 24h fixo (como Fmt.minutes e weekdayTime) em vez de
                    // timeStyle .short, que em en_US virava 12h "8:05 PM" e
                    // misturava formatos na mesma tela.
                    formatter.setLocalizedDateFormatFromTemplate("HH:mm")
                case .dayTime:
                    formatter.dateStyle = .short
                    formatter.timeStyle = .short
                    formatter.doesRelativeDateFormatting = true
                case .weekdayTime:
                    formatter.setLocalizedDateFormatFromTemplate("EEE HH:mm")
                }
                result[Key(language: language, style: style)] = formatter
            }
        }
        return result
    }()

    private static func formatter(language: AppLanguage, style: Style) -> DateFormatter {
        formatters[Key(language: language, style: style)]!
    }

    static func hhmm(_ date: Date, language: AppLanguage = .english) -> String {
        formatter(language: language, style: .hhmm).string(from: date)
    }

    static func dayTime(_ date: Date, language: AppLanguage = .english) -> String {
        formatter(language: language, style: .dayTime).string(from: date)
    }

    /// Tempo restante compacto para a barra: "3h12".
    static func remaining(until end: Date, from now: Date) -> String {
        let secs = max(0, Int(end.timeIntervalSince(now)))
        return "\(secs / 3600)h" + String(format: "%02d", (secs % 3600) / 60)
    }

    /// "qua 08:00" — dia da semana curto + hora, para próximas execuções.
    static func weekdayTime(_ date: Date, language: AppLanguage = .english) -> String {
        formatter(language: language, style: .weekdayTime).string(from: date)
    }

    /// Horário de um disparo no painel: só "21:00" quando é hoje;
    /// "sáb 21:00" quando cai em outro dia, para não parecer iminente.
    static func eventTime(_ date: Date, now: Date, calendar: Calendar = .current,
                          language: AppLanguage = .english) -> String {
        calendar.isDate(date, inSameDayAs: now)
            ? hhmm(date, language: language)
            : weekdayTime(date, language: language)
    }

    /// Minutos desde a meia-noite → "08:00".
    static func minutes(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }
}
