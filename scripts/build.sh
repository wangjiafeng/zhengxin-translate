#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
APP_PROJECT="$PROJECT_DIR/App/正心Translate.xcodeproj"
DERIVED_DATA="$PROJECT_DIR/Build/DerivedData"

xcodebuild \
  -project "$APP_PROJECT" \
  -scheme "正心Translate" \
  -configuration Debug \
  -destination "platform=macOS" \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  build

APP="$DERIVED_DATA/Build/Products/Debug/正心Translate.app"
file "$APP/Contents/MacOS/正心Translate"
echo "Built: $APP"


# Bundle the headless CLI alongside the GUI executable.
ZHENGXIN_CLI_BUNDLE_RUNTIME=0 zsh "$SCRIPT_DIR/build-cli.sh"
cp "$PROJECT_DIR/Build/CLI/zhengxin-translate" "$APP/Contents/MacOS/"
cp "$PROJECT_DIR/CLI/tools.json" "$APP/Contents/MacOS/"
