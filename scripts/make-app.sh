#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

UNIVERSAL_BINARY=""
cleanup() {
    if [[ -n "$UNIVERSAL_BINARY" ]]; then
        rm -f "$UNIVERSAL_BINARY"
    fi
}
trap cleanup EXIT

# Localmente, o default continua sendo a arquitetura do host. A release usa
# triples públicos do SwiftPM e une as slices em um único app universal.
UNIVERSAL_BUILD="${OHAYO_UNIVERSAL_BUILD:-0}"
case "$UNIVERSAL_BUILD" in
    0|1) ;;
    *)
        echo "erro: OHAYO_UNIVERSAL_BUILD deve ser 0 ou 1" >&2
        exit 1
        ;;
esac

if [[ "$UNIVERSAL_BUILD" == 0 ]]; then
    swift build -c release
    BUILD_DIR="$(swift build -c release --show-bin-path)"
    BINARY_SOURCE="$BUILD_DIR/Ohayo"
    RESOURCE_BUNDLE="$BUILD_DIR/Ohayo_Ohayo.bundle"
else
    BUILD_ARCHS=(arm64 x86_64)
    BUILD_TRIPLES=(arm64-apple-macosx13.0 x86_64-apple-macosx13.0)
    ARCH_BINARIES=()
    ARCH_BUILD_DIRS=()
    for index in "${!BUILD_TRIPLES[@]}"; do
        arch="${BUILD_ARCHS[$index]}"
        triple="${BUILD_TRIPLES[$index]}"
        swift build -c release --triple "$triple"
        arch_build_dir="$(
            swift build -c release --triple "$triple" --show-bin-path
        )"
        arch_binary="$arch_build_dir/Ohayo"
        [[ -x "$arch_binary" ]] || {
            echo "erro: binário $arch ausente: $arch_binary" >&2
            exit 1
        }
        ARCH_BUILD_DIRS+=("$arch_build_dir")
        ARCH_BINARIES+=("$arch_binary")
    done

    RESOURCE_BUNDLE="${ARCH_BUILD_DIRS[0]}/Ohayo_Ohayo.bundle"
    for arch_build_dir in "${ARCH_BUILD_DIRS[@]:1}"; do
        diff -qr "$RESOURCE_BUNDLE" \
            "$arch_build_dir/Ohayo_Ohayo.bundle" >/dev/null || {
            echo "erro: resource bundles diferem entre arquiteturas" >&2
            exit 1
        }
    done

    UNIVERSAL_BINARY="$(mktemp "${TMPDIR:-/tmp}/ohayo-universal.XXXXXX")"
    lipo -create "${ARCH_BINARIES[@]}" -output "$UNIVERSAL_BINARY"
    for arch in "${BUILD_ARCHS[@]}"; do
        lipo "$UNIVERSAL_BINARY" -verify_arch "$arch"
    done
    BINARY_SOURCE="$UNIVERSAL_BINARY"
fi

APP="build/Ohayo.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp "$BINARY_SOURCE" "$APP/Contents/MacOS/Ohayo"
cp scripts/Info.plist "$APP/Contents/Info.plist"
for localization in scripts/*.lproj; do
    [[ -d "$localization" ]] || continue
    cp -R "$localization" "$APP/Contents/Resources/"
    [[ -f "$APP/Contents/Resources/$(basename "$localization")/InfoPlist.strings" ]] || {
        echo "erro: strings localizadas ausentes em $localization" >&2
        exit 1
    }
done
# O bundle de recursos (SVGs dos providers) é obrigatório: sem ele o app
# instalado perde os ícones, e um empacotamento silencioso sem o bundle já
# passou despercebido numa release. Falhar alto aqui.
cp -R "$RESOURCE_BUNDLE" "$APP/Contents/Resources/"
[[ -d "$APP/Contents/Resources/Ohayo_Ohayo.bundle" ]] || {
    echo "erro: $RESOURCE_BUNDLE ausente — resource bundle não foi empacotado" >&2
    exit 1
}

# Ícone: a partir de um único master 1024x1024 (assets/AppIcon.png), gera todos
# os tamanhos que o macOS exige e compila o .icns. macOS não arredonda sozinho —
# o formato squircle e a margem vão desenhados no próprio PNG.
ICON_MASTER="assets/AppIcon.png"
if [[ -f "$ICON_MASTER" ]]; then
    ICONSET="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "$ICONSET"
    for size in 16 32 128 256 512; do
        sips -z "$size" "$size"     "$ICON_MASTER" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
        sips -z $((size*2)) $((size*2)) "$ICON_MASTER" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
    rm -rf "$(dirname "$ICONSET")"
else
    echo "aviso: $ICON_MASTER ausente — app sem ícone (coloque um PNG 1024x1024)"
fi

# Assina por último, depois de Resources/ estar completo. Builds locais usam
# assinatura ad-hoc; a release pode injetar uma identidade Developer ID pelo
# ambiente sem manter certificados ou nomes pessoais no repositório.
CODESIGN_IDENTITY="${OHAYO_CODESIGN_IDENTITY:--}"
CODESIGN_KEYCHAIN="${OHAYO_CODESIGN_KEYCHAIN:-}"
ENTITLEMENTS="scripts/Ohayo.entitlements"
[[ -f "$ENTITLEMENTS" ]] || {
    echo "erro: entitlements de distribuição ausentes: $ENTITLEMENTS" >&2
    exit 1
}
plutil -lint "$ENTITLEMENTS" >/dev/null
CODESIGN_ARGS=(
    --force
    --sign "$CODESIGN_IDENTITY"
    --entitlements "$ENTITLEMENTS"
)

if [[ "$CODESIGN_IDENTITY" != "-" ]]; then
    # A Apple exige hardened runtime e secure timestamp para notarização.
    CODESIGN_ARGS+=(--options runtime --timestamp)
    if [[ -n "$CODESIGN_KEYCHAIN" ]]; then
        [[ -f "$CODESIGN_KEYCHAIN" ]] || {
            echo "erro: keychain de assinatura não encontrado: $CODESIGN_KEYCHAIN" >&2
            exit 1
        }
        CODESIGN_ARGS+=(--keychain "$CODESIGN_KEYCHAIN")
    fi
fi

codesign "${CODESIGN_ARGS[@]}" "$APP"
codesign --verify --deep --strict "$APP"
codesign --display --entitlements - "$APP" 2>&1 \
    | grep -q "com.apple.security.automation.apple-events" || {
        echo "erro: app assinado sem entitlement de automação Apple Events" >&2
        exit 1
    }

if [[ "$CODESIGN_IDENTITY" == "-" ]]; then
    echo "Assinatura: ad-hoc (build local, não notarizado)"
else
    echo "Assinatura: identidade configurada, hardened runtime e timestamp habilitados"
fi
echo "Gerado: $APP"
