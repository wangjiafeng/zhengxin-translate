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

