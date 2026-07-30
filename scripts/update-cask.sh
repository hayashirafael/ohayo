#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Gera Casks/ohayo.rb a partir da versão + sha256 do DMG. Usado tanto no
# release CI (que empurra pro tap hayashirafael/homebrew-tap) quanto localmente
# pra conferir o cask antes de publicar. Mantém o .rb reproduzível — nunca
# editado à mão.
VERSION="${1:?uso: update-cask.sh <versao> <caminho-do-dmg> [dir-de-saida]}"
DMG="${2:?uso: update-cask.sh <versao> <caminho-do-dmg> [dir-de-saida]}"
OUT_DIR="${3:-Casks}"

[[ -f "$DMG" ]] || { echo "erro: DMG não encontrado: $DMG"; exit 1; }

SHA256="$(shasum -a 256 "$DMG" | awk '{print $1}')"
mkdir -p "$OUT_DIR"
CASK="$OUT_DIR/ohayo.rb"

cat > "$CASK" <<RUBY
# typed: strict
# frozen_string_literal: true

cask "ohayo" do
  version "${VERSION}"
  sha256 "${SHA256}"

  url "https://github.com/hayashirafael/ohayo/releases/download/v#{version}/Ohayo-#{version}.dmg"
  name "Ohayo"
  desc "Menu bar scheduler for Claude and Codex usage windows and commands"
  homepage "https://github.com/hayashirafael/ohayo"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true

  depends_on macos: :ventura

  app "Ohayo.app"

  zap trash: "~/Library/Preferences/io.github.hayashirafael.Ohayo.plist"

  caveats <<~EOS
    Interactive Claude/Codex tasks open Terminal. On first use, macOS may ask
    you to allow Ohayo to automate Terminal in:

      System Settings → Privacy & Security → Automation
  EOS
end
RUBY

echo "Gerado: $CASK (sha256 $SHA256)"
