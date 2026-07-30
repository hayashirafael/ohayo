#!/bin/bash
set -euo pipefail

required_names=(
    OHAYO_CODESIGN_IDENTITY
    OHAYO_CODESIGN_CERTIFICATE_BASE64
    OHAYO_CODESIGN_CERTIFICATE_PASSWORD
    OHAYO_NOTARY_APPLE_ID
    OHAYO_NOTARY_TEAM_ID
    OHAYO_NOTARY_APP_SPECIFIC_PASSWORD
    OHAYO_SPARKLE_PRIVATE_KEY
)

missing_names=()
for variable_name in "${required_names[@]}"; do
    if [[ -z "${!variable_name-}" ]]; then
        missing_names+=("$variable_name")
    fi
done

if (( ${#missing_names[@]} > 0 )); then
    echo "::error::Release pública exige Developer ID, notarização e assinatura Sparkle. Secrets ausentes: ${missing_names[*]}" >&2
    exit 1
fi

emit_output() {
    printf '%s\n' "$1"
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
        printf '%s\n' "$1" >> "$GITHUB_OUTPUT"
    fi
}

for variable_name in "${required_names[@]}"; do
    if [[ "$variable_name" == "OHAYO_CODESIGN_IDENTITY" ]] \
        && [[ "${!variable_name}" != "Developer ID Application:"* ]]; then
        echo "::error::OHAYO_CODESIGN_IDENTITY deve ser uma identidade Developer ID Application." >&2
        exit 1
    fi
done

emit_output "distribution_mode=developer_id"
emit_output "signing_enabled=true"
emit_output "notarization_enabled=true"
