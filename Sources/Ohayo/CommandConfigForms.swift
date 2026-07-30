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
    @Binding var trustWorkingDirectory: Bool
    let accounts: [URL]
    let accountLabel: (URL) -> String
    let strings: L10n
    var showsAccount = true

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 7) {
            GridRow {
                ConfigRowLabel(strings.model)
                Picker("", selection: $model) {
                    ForEach(Message.Model.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .accessibilityLabel(strings.model)
            }
            GridRow {
                ConfigRowLabel(strings.effort)
                Picker("", selection: $effort) {
                    ForEach(Message.Effort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .accessibilityLabel(strings.effort)
            }
            if showsAccount {
                GridRow {
                    ConfigRowLabel(strings.account)
                    Picker("", selection: $configDir) {
                        Text(strings.globalDefault).tag(String?.none)
                        ForEach(accounts, id: \.self) { dir in
                            Text(accountLabel(dir)).tag(String?.some(dir.path))
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel(strings.account)
                }
            }
            SkillPickerRows(skill: $skill, availableSkills: availableSkills, strings: strings)
            GridRow {
                ConfigRowLabel("")
                WorkingDirectoryPicker(
                    workingDir: $workingDir,
                    trustWorkingDirectory: $trustWorkingDirectory,
                    strings: strings
                )
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
    @Binding var accessMode: CodexAccessMode
    let availableModels: [CodexModelOption]
    @Binding var configDir: String?
    @Binding var skill: String?
    let availableSkills: [SkillRef]
    @Binding var workingDir: String
    let accounts: [URL]
    let accountLabel: (URL) -> String
    let strings: L10n
    var showsAccount = true

    private var selectedModel: CodexModelOption? {
        availableModels.first { $0.slug == model }
    }

    private var availableReasoning: [Message.CodexReasoning] {
        let base: [Message.CodexReasoning]
        if let selectedModel {
            base = selectedModel.supportedReasoning
        } else {
            base = availableModels.reduce(into: []) { result, option in
                for effort in option.supportedReasoning
                where !result.contains(effort) {
                    result.append(effort)
                }
            }
        }
        guard let reasoning, !base.contains(reasoning) else { return base }
        return base + [reasoning]
    }

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 7) {
            GridRow {
                ConfigRowLabel(strings.model)
                Picker("", selection: $model) {
                    Text(strings.accountDefaultModel).tag("")
                    ForEach(availableModels) { option in
                        Text(option.displayName).tag(option.slug)
                    }
                    if !model.isEmpty, selectedModel == nil {
                        Text(model).tag(model)
                    }
                }
                .labelsHidden()
                .accessibilityLabel(strings.model)
                .help(selectedModel?.description ?? "")
            }
            GridRow {
                ConfigRowLabel(strings.reasoning)
                Picker("", selection: $reasoning) {
                    Text(strings.accountDefaultReasoning).tag(Message.CodexReasoning?.none)
                    ForEach(availableReasoning, id: \.self) {
                        Text($0.rawValue).tag(Message.CodexReasoning?.some($0))
                    }
                }
                .labelsHidden()
                .accessibilityLabel(strings.reasoning)
            }
            if showsAccount {
                GridRow {
                    ConfigRowLabel(strings.account)
                    Picker("", selection: $configDir) {
                        Text(strings.codexDefault).tag(String?.none)
                        ForEach(accounts, id: \.self) { dir in
                            Text(accountLabel(dir)).tag(String?.some(dir.path))
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel(strings.account)
                }
            }
            SkillPickerRows(skill: $skill, availableSkills: availableSkills, strings: strings)
            GridRow {
                ConfigRowLabel("")
                WorkingDirectoryPicker(
                    workingDir: $workingDir,
                    trustWorkingDirectory: nil,
                    strings: strings
                )
            }
            GridRow {
                ConfigRowLabel(strings.codexAccess)
                VStack(alignment: .leading, spacing: 4) {
                    Picker("", selection: $accessMode) {
                        ForEach(CodexAccessMode.allCases, id: \.self) {
                            Text(strings.codexAccessMode($0)).tag($0)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityLabel(strings.codexAccess)

                    Text(strings.codexAccessModeHelp(accessMode))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.caption)
        .onChange(of: model) { newModel in
            reasoning = CodexModelCatalog.normalizedReasoning(
                reasoning,
                for: newModel,
                in: availableModels
            )
        }
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

/// Limite opcional do processo que o Ohayo acompanha. A duração fica vazia
/// enquanto o recurso está desligado e aceita qualquer inteiro positivo.
struct TimeoutEditor: View {
    @Binding var isEnabled: Bool
    @Binding var minutes: Int?
    let strings: L10n

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(strings.limitDuration, isOn: $isEnabled)
                .toggleStyle(.checkbox)
            if isEnabled {
                HStack(spacing: 6) {
                    TextField(
                        strings.durationInMinutes,
                        value: $minutes,
                        format: .number
                    )
                    .frame(width: 88)
                    .accessibilityLabel(strings.durationInMinutes)
                    Text(strings.minutesUnit)
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 20)
            }
        }
        .font(.caption)
    }
}

struct WorkingDirectoryPicker: View {
    @Binding var workingDir: String
    let trustWorkingDirectory: Binding<Bool>?
    let strings: L10n

    private var isEmpty: Bool {
        workingDir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var displayText: String {
        isEmpty ? strings.workingDirectoryDefault
            : (workingDir as NSString).abbreviatingWithTildeInPath
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button(action: chooseDirectory) {
                    HStack(spacing: 6) {
                        Image(systemName: "folder")
                        Text(displayText)
                            .foregroundStyle(
                                isEmpty ? .secondary : .primary
                            )
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .help(strings.workingDirectoryDefault)

                if !isEmpty {
                    Button { workingDir = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .help(strings.clearWorkingDirectory)
                    .accessibilityLabel(strings.clearWorkingDirectory)
                }
            }

            if !isEmpty, let trustWorkingDirectory {
                Toggle(
                    strings.trustWorkingDirectory,
                    isOn: trustWorkingDirectory
                )
                .toggleStyle(.checkbox)
                .help(strings.trustWorkingDirectoryHelp)

                Text(strings.trustWorkingDirectoryHelp)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.message = strings.workingDirectoryTrustNotice
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
            .accessibilityLabel(strings.skillLabel)
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
