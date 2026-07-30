import SwiftUI

/// Aviso in-app compartilhado pelo painel da barra de menus e pela tela Geral.
struct UpdateAvailableNotice: View {
    let version: String
    let strings: L10n
    let update: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.title3)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            Text(strings.updateAvailableTitle(version: version))
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Spacer(minLength: 4)

            Button(strings.updateNow, action: update)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .lineLimit(1)
        }
        .padding(10)
        .background(
            Color.accentColor.opacity(0.12),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .accessibilityElement(children: .contain)
    }
}
