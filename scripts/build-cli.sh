#!/bin/zsh
set -euo pipefail
SCRIPT_DIR="${0:A:h}"
ROOT="${SCRIPT_DIR:h}"
OUT="${ZHENGXIN_CLI_OUTPUT:-$ROOT/Build/CLI}"
mkdir -p "$OUT"
STAGE=$(mktemp -d "${TMPDIR:-/private/tmp}/zhengxin-cli-source.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
cp "$ROOT/CLI/macOS/"*.swift "$STAGE/"
for SOURCE in Models JobControl DocumentService ExportService ModelManager TranslationService; do
  cp "$ROOT/App/正心Translate/$SOURCE.swift" "$STAGE/"
done
ARCHS=(${=ZHENGXIN_CLI_ARCHS:-arm64 x86_64})
for ARCH in $ARCHS; do
  xcrun swiftc -O -parse-as-library -target "$ARCH-apple-macos14.0" \
    -module-cache-path "${TMPDIR:-/private/tmp}/zhengxin-cli-module-cache" \
    "$STAGE/Host.swift" "$STAGE/Main.swift" \
    "$STAGE/Models.swift" "$STAGE/JobControl.swift" \
    "$STAGE/DocumentService.swift" "$STAGE/ExportService.swift" \
    "$STAGE/ModelManager.swift" "$STAGE/TranslationService.swift" \
    -o "$OUT/zhengxin-translate-$ARCH"
done
lipo -create "${(@)ARCHS/#/$OUT/zhengxin-translate-}" -output "$OUT/zhengxin-translate"
cp "$ROOT/CLI/tools.json" "$OUT/tools.json"
# Standalone distribution includes existing native runtime, never the model.
if [[ "${ZHENGXIN_CLI_BUNDLE_RUNTIME:-1}" == "1" ]]; then
  mkdir -p "$OUT/Runtime"
  for ARCH in $ARCHS; do ditto "$ROOT/Runtime/$ARCH" "$OUT/Runtime/$ARCH"; done
fi
printf 'Built: %s\n' "$OUT/zhengxin-translate"
