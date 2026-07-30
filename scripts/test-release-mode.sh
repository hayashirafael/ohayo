#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

MODE_SCRIPT="$PWD/scripts/configure-release-mode.sh"
TEST_PATH="${PATH:-/usr/bin:/bin}"

if env -i \
    PATH="$TEST_PATH" \
    OHAYO_SPARKLE_PRIVATE_KEY="test-only-key" \
    "$MODE_SCRIPT" >/dev/null 2>&1; then
    echo "erro: release pública sem Developer ID/notarização deveria falhar" >&2
    exit 1
fi

developer_id_output="$(
    env -i \
        PATH="$TEST_PATH" \
        OHAYO_SPARKLE_PRIVATE_KEY="test-only-key" \
        OHAYO_CODESIGN_IDENTITY="Developer ID Application: Test" \
        OHAYO_CODESIGN_CERTIFICATE_BASE64="test-certificate" \
        OHAYO_CODESIGN_CERTIFICATE_PASSWORD="test-password" \
        OHAYO_NOTARY_APPLE_ID="developer@example.com" \
        OHAYO_NOTARY_TEAM_ID="TESTTEAMID" \
        OHAYO_NOTARY_APP_SPECIFIC_PASSWORD="test-app-password" \
        "$MODE_SCRIPT"
)"
grep -qx 'distribution_mode=developer_id' <<<"$developer_id_output"
grep -qx 'signing_enabled=true' <<<"$developer_id_output"
grep -qx 'notarization_enabled=true' <<<"$developer_id_output"

if env -i \
    PATH="$TEST_PATH" \
    OHAYO_SPARKLE_PRIVATE_KEY="test-only-key" \
    OHAYO_CODESIGN_IDENTITY="Developer ID Application: Test" \
    "$MODE_SCRIPT" >/dev/null 2>&1; then
    echo "erro: configuração Apple parcial deveria falhar" >&2
    exit 1
fi

if env -i \
    PATH="$TEST_PATH" \
    OHAYO_SPARKLE_PRIVATE_KEY="test-only-key" \
    OHAYO_CODESIGN_IDENTITY="Apple Development: Test" \
    OHAYO_CODESIGN_CERTIFICATE_BASE64="test-certificate" \
    OHAYO_CODESIGN_CERTIFICATE_PASSWORD="test-password" \
    OHAYO_NOTARY_APPLE_ID="developer@example.com" \
    OHAYO_NOTARY_TEAM_ID="TESTTEAMID" \
    OHAYO_NOTARY_APP_SPECIFIC_PASSWORD="test-app-password" \
    "$MODE_SCRIPT" >/dev/null 2>&1; then
    echo "erro: identidade que não é Developer ID deveria falhar" >&2
    exit 1
fi

if env -i PATH="$TEST_PATH" "$MODE_SCRIPT" >/dev/null 2>&1; then
    echo "erro: release sem chave EdDSA deveria falhar" >&2
    exit 1
fi

echo "Modos de release validados."
