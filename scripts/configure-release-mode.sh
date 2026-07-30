#!/bin/bash
set -euo pipefail

signing_names=(
    OHAYO_CODESIGN_IDENTITY
    OHAYO_CODESIGN_CERTIFICATE_BASE64
    OHAYO_CODESIGN_CERTIFICATE_PASSWORD
)
notary_names=(
    OHAYO_NOTARY_APPLE_ID
    OHAYO_NOTARY_TEAM_ID
    OHAYO_NOTARY_APP_SPECIFIC_PASSWORD
)

count_configured() {
    local count=0
    local variable_name
    for variable_name in "$@"; do
        [[ -z "${!variable_name-}" ]] || count=$((count + 1))
    done
    printf '%s\n' "$count"
}

emit_output() {
    printf '%s\n' "$1"
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
        printf '%s\n' "$1" >> "$GITHUB_OUTPUT"
    fi
}

signing_count="$(count_configured "${signing_names[@]}")"
notary_count="$(count_configured "${notary_names[@]}")"

if [[ -z "${OHAYO_SPARKLE_PRIVATE_KEY:-}" ]]; then
    echo "::error::Toda release exige OHAYO_SPARKLE_PRIVATE_KEY para assinar as atualizações do Sparkle." >&2
    exit 1
fi

if (( signing_count == 0 && notary_count == 0 )); then
    echo "::warning::Release gratuita para testers: assinatura ad-hoc, sem notarização Apple. A primeira instalação exigirá aprovação manual no Gatekeeper." >&2
    emit_output "distribution_mode=adhoc"
    emit_output "signing_enabled=false"
    emit_output "notarization_enabled=false"
    exit 0
fi

if (( signing_count == ${#signing_names[@]} \
    && notary_count == ${#notary_names[@]} )); then
    if [[ "$OHAYO_CODESIGN_IDENTITY" != "Developer ID Application:"* ]]; then
        echo "::error::OHAYO_CODESIGN_IDENTITY deve ser uma identidade Developer ID Application." >&2
        exit 1
    fi
    emit_output "distribution_mode=developer_id"
    emit_output "signing_enabled=true"
    emit_output "notarization_enabled=true"
    exit 0
fi

echo "::error::Configuração Apple incompleta. Para ativar Developer ID, defina juntos: ${signing_names[*]} ${notary_names[*]}. Para o modo gratuito, não defina nenhum deles." >&2
exit 1
