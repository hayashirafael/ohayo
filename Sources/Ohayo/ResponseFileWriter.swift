import Foundation

enum ResponseFileWriteError: Error, Equatable {
    case failed(String)
}

protocol ResponseFileWriting {
    func write(
        response: String,
        format: ResponseFileFormat,
        directory: URL,
        taskName: String?,
        date: Date
    ) async -> Result<URL, ResponseFileWriteError>
}

struct SystemResponseFileWriter: ResponseFileWriting {
    func write(
        response: String,
        format: ResponseFileFormat,
        directory: URL,
        taskName: String?,
        date: Date
    ) async -> Result<URL, ResponseFileWriteError> {
        do {
            let targetDirectory = directory.standardizedFileURL
            try FileManager.default.createDirectory(
                at: targetDirectory,
                withIntermediateDirectories: true
            )
            let file = targetDirectory.appendingPathComponent(
                Self.fileName(
                    taskName: taskName,
                    date: date,
                    format: format
                )
            )
            try Data(response.utf8).write(to: file, options: .atomic)
            return .success(file)
        } catch {
            return .failure(.failed(error.localizedDescription))
        }
    }

    private static func fileName(
        taskName: String?,
        date: Date,
        format: ResponseFileFormat
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let timestamp = formatter.string(from: date)
        let title = slug(taskName ?? "") ?? "resposta"
        let unique = UUID().uuidString.prefix(8).lowercased()
        return "\(timestamp)_\(title)-\(unique).\(format.fileExtension)"
    }

    private static func slug(_ value: String) -> String? {
        let folded = value.folding(
            options: [.diacriticInsensitive, .caseInsensitive],
            locale: Locale(identifier: "pt_BR")
        ).lowercased()
        let pieces = folded.components(
            separatedBy: CharacterSet.alphanumerics.inverted
        ).filter { !$0.isEmpty }
        let result = pieces.joined(separator: "-")
        return result.isEmpty ? nil : String(result.prefix(60))
    }
}
