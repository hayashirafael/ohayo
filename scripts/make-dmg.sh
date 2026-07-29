#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Builda o .app e empacota num DMG de arrastar-para-Applications — o formato
# padrão de instalador de apps macOS fora da App Store. Sem configuração, o app
# usa assinatura ad-hoc; a release pode injetar uma identidade Developer ID.
./scripts/make-app.sh

APP="build/Ohayo.app"
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" scripts/Info.plist)"
DMG="build/Ohayo-${VERSION}.dmg"
rm -f "$DMG"

# Staging limpo: só o app (o symlink para /Applications é adicionado abaixo),
# senão o DMG carregaria lixo do diretório build/.
STAGING="$(mktemp -d)"
MOUNT_POINT=""
DMG_MOUNTED=false
cleanup() {
    if [[ "$DMG_MOUNTED" == true && -n "$MOUNT_POINT" ]]; then
        hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1 || true
    fi
    if [[ -n "$MOUNT_POINT" ]]; then
        rmdir "$MOUNT_POINT" >/dev/null 2>&1 || true
    fi
    rm -rf "$STAGING"
}
trap cleanup EXIT
cp -R "$APP" "$STAGING/"

if command -v create-dmg >/dev/null 2>&1; then
    # create-dmg (Homebrew): janela estilizada com o app e o atalho Applications
    # posicionados. --hdiutil-quiet evita ruído.
    set +e
    create-dmg \
        --volname "Ohayo" \
        --window-pos 200 120 \
        --window-size 600 380 \
        --icon-size 100 \
        --icon "Ohayo.app" 150 190 \
        --app-drop-link 450 190 \
        --hide-extension "Ohayo.app" \
        "$DMG" "$STAGING"
    CREATE_DMG_STATUS=$?
    set -e
    # Qualquer status não-zero é falha real. Mesmo que exista um arquivo
    # parcial, ele não pode avançar para publicação.
    if [[ "$CREATE_DMG_STATUS" -ne 0 ]]; then
        rm -f "$DMG"
        echo "erro: create-dmg falhou com status $CREATE_DMG_STATUS" >&2
        exit "$CREATE_DMG_STATUS"
    fi
else
    echo "aviso: create-dmg não encontrado (brew install create-dmg) — DMG simples via hdiutil"
    ln -s /Applications "$STAGING/Applications"
    hdiutil create -volname "Ohayo" -srcfolder "$STAGING" \
        -ov -format UDZO "$DMG" >/dev/null
fi

[[ -s "$DMG" ]] || { echo "erro: DMG não foi gerado ou está vazio"; exit 1; }

# Um DMG de release também é assinado quando há identidade configurada. O
# hardened runtime é uma propriedade do executável; para o contêiner basta a
# assinatura com secure timestamp.
CODESIGN_IDENTITY="${OHAYO_CODESIGN_IDENTITY:-}"
if [[ -n "$CODESIGN_IDENTITY" && "$CODESIGN_IDENTITY" != "-" ]]; then
    DMG_CODESIGN_ARGS=(--force --sign "$CODESIGN_IDENTITY" --timestamp)
    if [[ -n "${OHAYO_CODESIGN_KEYCHAIN:-}" ]]; then
        DMG_CODESIGN_ARGS+=(--keychain "$OHAYO_CODESIGN_KEYCHAIN")
    fi
    codesign "${DMG_CODESIGN_ARGS[@]}" "$DMG"
    codesign --verify --strict "$DMG"
fi

hdiutil verify "$DMG" >/dev/null

# A imagem só é válida para distribuição se for montável em modo somente
# leitura e contiver exatamente os dois pontos de entrada esperados.
MOUNT_POINT="$(mktemp -d)"
hdiutil attach "$DMG" \
    -readonly \
    -nobrowse \
    -noautoopen \
    -mountpoint "$MOUNT_POINT" >/dev/null
DMG_MOUNTED=true

[[ -d "$MOUNT_POINT/Ohayo.app" ]] || {
    echo "erro: DMG não contém Ohayo.app" >&2
    exit 1
}
[[ -L "$MOUNT_POINT/Applications" ]] || {
    echo "erro: DMG não contém o link para Applications" >&2
    exit 1
}
[[ "$(readlink "$MOUNT_POINT/Applications")" == "/Applications" ]] || {
    echo "erro: link Applications do DMG aponta para destino inesperado" >&2
    exit 1
}
codesign --verify --deep --strict "$MOUNT_POINT/Ohayo.app"

hdiutil detach "$MOUNT_POINT" >/dev/null
DMG_MOUNTED=false
rmdir "$MOUNT_POINT"
MOUNT_POINT=""

echo "Gerado: $DMG"
