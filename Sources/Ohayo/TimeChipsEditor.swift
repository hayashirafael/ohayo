import SwiftUI

/// Editor de horários como chips: lista sempre ordenada e sem duplicatas.
/// Clicar num chip edita in place, × remove (mínimo de um horário), ＋
/// adiciona e "Gerar a cada 5h…" substitui a lista pela cadeia de janelas.
struct TimeChipsEditor: View {
    @Binding var times: [Int]
    let strings: L10n

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 74), spacing: 6)],
                      alignment: .leading, spacing: 6) {
                // id: \.self é seguro: a lista normalizada não tem duplicatas.
                ForEach(times, id: \.self) { minutes in
                    TimeChip(minutes: minutes,
                             removable: times.count > 1,
                             strings: strings,
                             onEdit: { replace(minutes, with: $0) },
                             onRemove: { remove(minutes) })
                }
            }
            HStack(spacing: 14) {
                AddTimeButton(defaultDraft: nextDraft(), strings: strings) { add($0) }
                GenerateChainButton(strings: strings) { anchor in
                    times = AgendaMath.chainTimes(anchor: anchor)
                }
            }
            .font(.caption)
        }
    }

    private func add(_ minutes: Int) {
        times = AgendaMath.normalized(times + [minutes])
    }

    private func replace(_ old: Int, with new: Int) {
        times = AgendaMath.normalized(times.filter { $0 != old } + [new])
    }

    private func remove(_ minutes: Int) {
        guard times.count > 1 else { return }
        times = times.filter { $0 != minutes }
    }

    private func nextDraft() -> Int {
        ((times.max() ?? 9 * 60) + 60) % 1440
    }
}

/// Um horário: botão que abre o editor + × para remover.
private struct TimeChip: View {
    let minutes: Int
    let removable: Bool
    let strings: L10n
    let onEdit: (Int) -> Void
    let onRemove: () -> Void
    @State private var showEditor = false

    var body: some View {
        HStack(spacing: 5) {
            Button(Fmt.minutes(minutes)) { showEditor = true }
                .buttonStyle(.plain)
                .accessibilityLabel(strings.editTime(Fmt.minutes(minutes)))
            if removable {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(strings.removeTime(Fmt.minutes(minutes)))
                .accessibilityLabel(strings.removeTime(Fmt.minutes(minutes)))
            }
        }
        .font(.callout.monospacedDigit())
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.6), in: Capsule())
        .popover(isPresented: $showEditor) {
            TimePickerPopover(title: strings.time, confirmLabel: strings.save,
                              minutes: minutes) { onEdit($0) }
        }
    }
}

/// "＋ Adicionar horário" com popover de DatePicker.
private struct AddTimeButton: View {
    let defaultDraft: Int
    let strings: L10n
    let onAdd: (Int) -> Void
    @State private var showAdd = false

    var body: some View {
        Button { showAdd = true } label: {
            Label(strings.addTime, systemImage: "plus.circle")
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showAdd) {
            TimePickerPopover(title: strings.time, confirmLabel: strings.add,
                              minutes: defaultDraft) { onAdd($0) }
        }
    }
}

/// "Gerar a cada 5h…": pede a âncora e substitui a lista pela cadeia.
private struct GenerateChainButton: View {
    let strings: L10n
    let onGenerate: (Int) -> Void
    @State private var showAnchor = false

    var body: some View {
        Button { showAnchor = true } label: {
            Label(strings.generateChain, systemImage: "clock.arrow.2.circlepath")
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showAnchor) {
            TimePickerPopover(title: strings.chainAnchor, confirmLabel: strings.generate,
                              minutes: 9 * 60) { onGenerate($0) }
        }
    }
}

/// Popover comum: DatePicker (hora e minuto) + botão de confirmação.
private struct TimePickerPopover: View {
    let title: String
    let confirmLabel: String
    @State var minutes: Int
    let onConfirm: (Int) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DatePicker(title, selection: dateBinding, displayedComponents: .hourAndMinute)
            HStack {
                Spacer()
                Button(confirmLabel) {
                    onConfirm(minutes)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
    }

    private var dateBinding: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60,
                                      second: 0, of: Date()) ?? Date()
            },
            set: { date in
                let p = Calendar.current.dateComponents([.hour, .minute], from: date)
                minutes = (p.hour ?? 0) * 60 + (p.minute ?? 0)
            })
    }
}
