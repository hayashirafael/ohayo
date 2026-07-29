import AppKit
import SwiftUI

struct ClaudeConfigForm: View {
    @Binding var model: Message.Model
    @Binding var effort: Message.Effort
    @Binding var safeMode: Bool
    @Binding var configDir: String?
    @Binding var skill: String?
    let availableSkills: [SkillRef]
    @Binding var workingDir: String
    let accounts: [URL]
    let accountLabel: (URL) -> String
    let strings: L10n

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 7) {
            GridRow {
                ConfigRowLabel(strings.model)
                Picker("", selection: $model) {
                    ForEach(Message.Model.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden()
            }
            GridRow {
                ConfigRowLabel(strings.effort)
                Picker("", selection: $effort) {
                    ForEach(Message.Effort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
            }
            GridRow {
                ConfigRowLabel(strings.account)
                Picker("", selection: $configDir) {
                    Text(strings.globalDefault).tag(String?.none)
                    ForEach(accounts, id: \.self) { dir in
                        Text(accountLabel(dir)).tag(String?.some(dir.path))
                    }
                }
                .labelsHidden()
            }
            SkillPickerRows(skill: $skill, availableSkills: availableSkills, strings: strings)
            GridRow {
                ConfigRowLabel("")
                WorkingDirectoryPicker(workingDir: $workingDir, strings: strings)
            }
            GridRow {
                ConfigRowLabel("")
                Toggle(strings.safeMode, isOn: $safeMode)
                    .toggleStyle(.checkbox)
                    // Skill exige safe-mode desligado (--safe-mode pularia a
                    // skill); o sheet zera o toggle ao selecionar uma skill.
                    .disabled(skill?.isEmpty == false)
                    .help(skill?.isEmpty == false ? strings.skillDisablesSafeMode : "")
            }
        }
        .font(.caption)
    }
}

struct CodexConfigForm: View {
    @Binding var model: String
    @Binding var reasoning: Message.CodexReasoning?
    @Binding var configDir: String?
    @Binding var skill: String?
    let availableSkills: [SkillRef]
    @Binding var workingDir: String
    let accounts: [URL]
    let accountLabel: (URL) -> String
    let strings: L10n

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 7) {
            GridRow {
                ConfigRowLabel(strings.model)
                TextField(strings.accountDefaultModel, text: $model)
            }
            GridRow {
                ConfigRowLabel(strings.reasoning)
                Picker("", selection: $reasoning) {
                    Text(strings.accountDefaultReasoning).tag(Message.CodexReasoning?.none)
                    ForEach(Message.CodexReasoning.allCases, id: \.self) {
                        Text($0.rawValue).tag(Message.CodexReasoning?.some($0))
                    }
                }
                .labelsHidden()
            }
            GridRow {
                ConfigRowLabel(strings.account)
                Picker("", selection: $configDir) {
                    Text(strings.codexDefault).tag(String?.none)
                    ForEach(accounts, id: \.self) { dir in
                        Text(accountLabel(dir)).tag(String?.some(dir.path))
                    }
                }
                .labelsHidden()
            }
            SkillPickerRows(skill: $skill, availableSkills: availableSkills, strings: strings)
            GridRow {
                ConfigRowLabel("")
                WorkingDirectoryPicker(workingDir: $workingDir, strings: strings)
            }
        }
        .font(.caption)
    }
}

/// Rótulo da coluna esquerda dos forms de config: coluna alinhada e discreta.
struct ConfigRowLabel: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
    }
}

/// Timeout do processo que o Ohayo acompanha. O valor opcional mantém o
/// payload enxuto: nil representa o default seguro de cada tipo de comando.
struct TimeoutPicker: View {
    @Binding var timeoutSeconds: Int?
    let kind: Message.Kind
    let strings: L10n

    private var selection: Binding<Int> {
        Binding(
            get: {
                timeoutSeconds ?? Message.defaultTimeoutSeconds(for: kind)
            },
            set: {
                timeoutSeconds = Message.normalizedTimeoutSeconds($0, for: kind)
            }
        )
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(strings.timeout)
                .foregroundStyle(.secondary)
            Picker("", selection: selection) {
                ForEach(Message.timeoutPresets, id: \.self) { seconds in
                    Text(Self.label(for: seconds)).tag(seconds)
                }
            }
            .labelsHidden()
            .accessibilityLabel(strings.timeout)
        }
    }

    static func label(for seconds: Int) -> String {
        let minutes = seconds / 60
        return minutes == 1 ? "1 min" : "\(minutes) min"
    }
}

struct WorkingDirectoryPicker: View {
    @Binding var workingDir: String
    let strings: L10n

    private var isEmpty: Bool {
        workingDir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var displayText: String {
        isEmpty ? strings.workingDirectoryDefault
            : (workingDir as NSString).abbreviatingWithTildeInPath
    }

    var body: some View {
        HStack(spacing: 6) {
            Button(action: chooseDirectory) {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                    Text(displayText)
                        .foregroundStyle(isEmpty ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
            .help(strings.workingDirectoryDefault)

            if !isEmpty {
                Button { workingDir = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .help(strings.clearWorkingDirectory)
            }
        }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.prompt = strings.chooseDirectory
        panel.directoryURL = initialDirectoryURL()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        workingDir = url.standardizedFileURL.path
    }

    private func initialDirectoryURL() -> URL {
        guard !isEmpty else { return FileManager.default.homeDirectoryForCurrentUser }
        let expanded = NSString(string: workingDir).expandingTildeInPath
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return URL(fileURLWithPath: expanded)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
}

/// Linhas do picker de skill compartilhadas pelos forms Claude/Codex:
/// "Nenhuma" + skills detectadas na conta; uma seleção que não existe mais na
/// conta vira entrada extra com aviso (salvar/disparar segue permitido).
struct SkillPickerRows: View {
    @Binding var skill: String?
    let availableSkills: [SkillRef]
    let strings: L10n

    private var missing: Bool {
        guard let skill, !skill.isEmpty else { return false }
        return !availableSkills.contains { $0.name == skill }
    }

    var body: some View {
        GridRow {
            ConfigRowLabel(strings.skillLabel)
            Picker("", selection: $skill) {
                Text(strings.noSkill).tag(String?.none)
                ForEach(availableSkills) { ref in
                    Text(ref.name).tag(String?.some(ref.name))
                }
                if missing, let skill {
                    Text(skill).tag(String?.some(skill))
                }
            }
            .labelsHidden()
        }
        if missing {
            GridRow {
                ConfigRowLabel("")
                Label(strings.skillNotFound, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        }
    }
}
